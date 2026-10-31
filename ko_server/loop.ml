let listen path =
  let server = Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  match
    Unix.bind server (Unix.ADDR_UNIX path);
    Unix.listen server 256;
    Unix.set_nonblock server
  with
  | () -> Ok server
  | exception Unix.Unix_error (error, _, _) ->
      Unix.close server;
      Error (Unix.error_message error)

let accept_burst = 16
let accept_retry_ms = 100

let run config =
  let socket = config.Config.socket in
  match listen socket with
  | Error _ as error -> error
  | Ok server ->
      let connections = ref [] in
      let rec state = lazy (State.create config ~activity)
      and ticker = lazy (Event_loop.timer tick)
      and activity () =
        let ticker = Lazy.force ticker in
        (not (Event_loop.is_active ticker))
        && begin
          Event_loop.start_timer ticker ~after:2 ~repeat:(Some 2);
          true
        end
      and tick () =
        let state = Lazy.force state in
        if (not (State.tick state)) && not (State.waiting state) then
          Event_loop.stop_timer (Lazy.force ticker)
      in
      let state = Lazy.force state in
      Event_loop.on_signal Sys.sigchld (fun () -> Panes.reap (State.panes state));
      let ping =
        Event_loop.timer (fun () ->
            let now = Unix.gettimeofday () in
            List.iter (fun c -> Connection.tick c now) !connections)
      in
      Event_loop.start_timer ping ~after:1000 ~repeat:(Some 1000);
      let listener = Event_loop.watch server in
      let resume = Event_loop.timer (fun () -> Event_loop.interest listener Read) in
      let admit fd =
        let accepted = try Native.peer_uid fd = Unix.getuid () with Unix.Unix_error _ -> false in
        if not accepted then Unix.close fd
        else
          match Unix.setsockopt_int fd Unix.SO_SNDBUF (1 lsl 20) with
          | exception Unix.Unix_error _ -> Unix.close fd
          | () ->
              let connection =
                Connection.accept fd
                  ~on_dispose:(fun closed ->
                    connections := List.filter (fun c -> not Stdlib.(c == closed)) !connections)
                  (Http.request state)
              in
              if not (Connection.is_closed connection) then
                connections := connection :: !connections
      in
      let rec accept remaining =
        if remaining > 0 then
          match Unix.accept ~cloexec:true server with
          | fd, _ ->
              admit fd;
              accept (remaining - 1)
          | exception Unix.Unix_error (Unix.ECONNABORTED, _, _) -> accept (remaining - 1)
          | exception
              Unix.Unix_error ((Unix.EMFILE | Unix.ENFILE | Unix.ENOBUFS | Unix.ENOMEM), _, _) ->
              Event_loop.interest listener Idle;
              Event_loop.start_timer resume ~after:accept_retry_ms ~repeat:None
          | exception Unix.Unix_error _ -> ()
      in
      Event_loop.handle listener (Ready (fun () -> accept accept_burst)) ~on_writable:ignore;
      Event_loop.interest listener Read;
      let stopping = ref false in
      Event_loop.on_signal Sys.sigterm (fun () ->
          if not !stopping then begin
            stopping := true;
            Event_loop.close listener;
            Event_loop.stop_timer resume;
            List.iter Connection.close !connections;
            Panes.shutdown (State.panes state);
            Event_loop.stop_timer (Lazy.force ticker);
            Event_loop.start_timer
              (Event_loop.timer (fun () ->
                   Panes.kill (State.panes state);
                   Panes.reap (State.panes state);
                   Event_loop.stop ()))
              ~after:500 ~repeat:None
          end);
      Event_loop.run ();
      (try Unix.unlink socket with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
      Ok ()
