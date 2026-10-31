let create ~paint ~notify =
  let reader, writer = Unix.pipe ~cloexec:true () in
  Unix.set_nonblock reader;
  Unix.set_nonblock writer;
  let buffer = Bytes.create 65536 and signal = Bytes.of_string "w" in
  let wake () =
    try ignore (Unix.write writer signal 0 1)
    with Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EBADF), _, _) -> ()
  in
  let previous_winch = Sys.signal Sys.sigwinch (Sys.Signal_handle (fun _ -> wake ())) in
  let parser = Matrix.Input.Parser.create () in
  let terminal = Matrix.Terminal.make ~output:(Fs.write_all Unix.stdout) () in
  let dimensions = ref (Matrix.Terminal.size Unix.stdout) in
  let raw = ref None and cleaned = ref false in
  let set_raw_mode enabled =
    match (enabled, !raw) with
    | true, None -> raw := Some (Matrix.Terminal.set_raw Unix.stdin)
    | false, Some saved ->
        Matrix.Terminal.restore Unix.stdin saved;
        raw := None
    | _ -> ()
  in
  let cleanup () =
    if not !cleaned then (
      cleaned := true;
      Sys.set_signal Sys.sigwinch previous_winch;
      Unix.close reader;
      Unix.close writer)
  in
  let wait timeout =
    try
      let ready, _, _ = Unix.select [ Unix.stdin; reader ] [] [] timeout in
      ready
    with Unix.Unix_error (Unix.EINTR, _, _) -> []
  in
  let rec drain () =
    try if Unix.read reader buffer 0 (Bytes.length buffer) > 0 then drain ()
    with Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
  in
  let backend : Matrix.Backend.t =
    {
      now = Unix.gettimeofday;
      wake;
      write_output = (fun _ _ _ -> ());
      read_input = (fun bytes off len -> Unix.read Unix.stdin bytes off len);
      wait_readable = (fun ~timeout -> List.mem ~eq:Stdlib.( = ) Unix.stdin (wait timeout));
      read_events =
        (fun ~timeout ~on_event ~on_response ->
          let ready = wait (Option.value ~default:(-1.) timeout) in
          if List.mem ~eq:Stdlib.( = ) reader ready then drain ();
          let size = Matrix.Terminal.size Unix.stdout in
          if not (Stdlib.( = ) size !dimensions) then (
            dimensions := size;
            let cols, rows = size in
            on_event (Matrix.Input.Resize (cols, rows)));
          let result =
            if List.mem ~eq:Stdlib.( = ) Unix.stdin ready then
              let n = Unix.read Unix.stdin buffer 0 (Bytes.length buffer) in
              if n = 0 then `End
              else (
                Matrix.Input.Parser.feed parser buffer 0 n ~now:(Unix.gettimeofday ()) ~on_event
                  ~on_response:(fun r ->
                    on_response r;
                    notify ());
                `Continue)
            else `Continue
          in
          Matrix.Input.Parser.drain parser ~now:(Unix.gettimeofday ()) ~on_event ~on_response;
          result);
      terminal_size = (fun () -> Matrix.Terminal.size Unix.stdout);
      set_raw_mode;
      flush_input = (fun () -> Matrix.Terminal.flush_input Unix.stdin);
      cleanup;
    }
  in
  try
    let session =
      Matrix.Backend.bootstrap ~mode:`Alt ~raw_mode:true ~input_is_tty:true ~terminal ~parser
        backend
    in
    let app =
      Matrix.attach ~backend ~terminal ~parser ~width:session.width ~height:session.height
        ~startup_events:session.startup_events ~target_fps:None ~exit_on_ctrl_c:false
        ~signal_handlers:false ~kitty_keyboard:`Disabled ~start_idle:true ~cursor_visible:false
        ~mouse_enabled:false ~resize_debounce:None ()
    in
    ignore (Matrix.Screen.post_process (fun _ ~delta:_ -> paint ()) (Matrix.screen app));
    app
  with e ->
    set_raw_mode false;
    Matrix.Terminal.close terminal;
    cleanup ();
    raise e
