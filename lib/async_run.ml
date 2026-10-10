let usage = "usage: kido async-run [--run-id ID]"
let signal_grace = 2.

let signal_name s =
  List.assoc_opt ~eq:Int.equal s
    Sys.
      [
        (sighup, "hangup");
        (sigint, "interrupt");
        (sigquit, "quit");
        (sigabrt, "aborted");
        (sigkill, "killed");
        (sigsegv, "segmentation fault");
        (sigpipe, "broken pipe");
        (sigalrm, "alarm clock");
        (sigterm, "terminated");
        (sigusr1, "user defined signal 1");
        (sigusr2, "user defined signal 2");
      ]
  |> Option.get_lazy (fun () -> Printf.sprintf "signal %d" s)

let rec write_all fd b off n =
  if n > 0 then
    let w = Unix.write fd b off n in
    write_all fd b (off + w) (n - w)

type child = { pid : int; out : Unix.file_descr; mutable eof : bool }

let rec pump ~file ~stream ~wake ~caught ~watch ~deadline child buf =
  let now = Unix.gettimeofday () in
  if watch && Option.is_some (Atomic.get caught) then `Signalled
  else if Float.(now >= deadline) then `Timeout
  else
    match if child.eof then Some (Unix.waitpid [ Unix.WNOHANG ] child.pid) else None with
    | Some (pid, status) when pid <> 0 -> `Exited status
    | _ ->
        let fds, timeout =
          if child.eof then ([ wake ], Float.min 0.05 (deadline -. now))
          else ([ wake; child.out ], if Float.is_finite deadline then deadline -. now else -1.)
        in
        (match Unix.select fds [] [] timeout with
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> ()
        | ready, _, _ ->
            (if List.memq wake ready then
               try ignore (Unix.read wake buf 0 (Bytes.length buf))
               with Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ());
            if List.memq child.out ready then
              begin match Unix.read child.out buf 0 (Bytes.length buf) with
              | 0 ->
                  child.eof <- true;
                  Unix.close child.out
              | n ->
                  (try write_all Unix.stdout buf 0 n with Unix.Unix_error _ -> ());
                  write_all file buf 0 n;
                  Option.iter (fun s -> Async_stream.write s (Bytes.sub_string buf 0 n)) stream
              end);
        pump ~file ~stream ~wake ~caught ~watch ~deadline child buf

let status_of = function
  | Unix.WEXITED 0 -> (Subrun.Completed, "exit status 0", 0)
  | WEXITED n -> (Failed, Printf.sprintf "exit status %d" n, n)
  | WSIGNALED s | WSTOPPED s -> (Failed, "signal: " ^ signal_name s, 1)

let async_run ~dir ~knobs ~warn ~run_id =
  let open Result.Infix in
  let* id =
    Result.map_err
      (fun _ -> "--run-id is required (or $KIDO_AGENT_RUN_ID)\n" ^ usage)
      (Subrun.parse_id run_id)
  in
  let* meta =
    Option.to_result (Printf.sprintf "run %s has no meta" run_id) (Subrun.read_meta ~dir id)
  in
  let* argv =
    match Subrun.read_command ~dir id with
    | Some (_ :: _ as argv) -> Ok argv
    | _ -> Error (Printf.sprintf "run %s has no command" run_id)
  in
  (* Armed before the output file exists, and so before the spawn: a signal arriving from then on is
     still ours to report. *)
  let wake, wake_w = Unix.pipe ~cloexec:true () in
  Unix.set_nonblock wake;
  Unix.set_nonblock wake_w;
  let caught = Atomic.make None in
  let handler s =
    if Atomic.compare_and_set caught None (Some s) then
      try ignore (Unix.write_substring wake_w "x" 0 1) with Unix.Unix_error _ -> ()
  in
  let signals = Sys.[ sigterm; sighup; sigint ] in
  let previous = List.map (fun s -> (s, Sys.signal s (Signal_handle handler))) signals in
  let file =
    Unix.openfile (Subrun.output_path ~dir id) [ O_WRONLY; O_CREAT; O_TRUNC; O_CLOEXEC ] 0o644
  in
  let stream =
    match meta.kind with
    | Stream -> Some (Async_stream.start ~dir knobs meta)
    | Agent | Bash -> None
  in
  let report result text =
    let detail =
      match stream with
      | Some s -> Reap.Streamed { unstreamed = Async_stream.close s }
      | None -> Reap.Bash
    in
    let outcome : Subrun.outcome = { result; text; at = Some (Timestamp.now ()) } in
    if Subrun.record_outcome ~dir id outcome then
      Result.iter_err
        (fun e -> warn (Msg.string_of_error e))
        (Reap.send ~dir { meta; outcome; detail })
  in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun (s, b) -> Sys.set_signal s b) previous;
      List.iter Unix.close [ wake; wake_w; file ])
    (fun () ->
      let out, out_w = Unix.pipe ~cloexec:true () in
      match Unix.create_process (List.hd argv) (Array.of_list argv) Unix.stdin out_w out_w with
      | exception Unix.Unix_error (e, _, _) ->
          List.iter Unix.close [ out; out_w ];
          let why = Printf.sprintf "exec: %S: %s" (List.hd argv) (Unix.error_message e) in
          report Failed why;
          Error why
      | pid -> (
          Unix.close out_w;
          let child = { pid; out; eof = false } in
          let buf = Bytes.create 65536 in
          let pump = pump ~file ~stream ~wake ~caught child buf in
          match pump ~watch:true ~deadline:Float.infinity with
          | `Exited status ->
              let result, text, code = status_of status in
              report result text;
              Ok code
          | `Signalled | `Timeout ->
              let s = Option.get_exn_or "caught" (Atomic.get caught) in
              (try Unix.kill pid s with Unix.Unix_error _ -> ());
              (match pump ~watch:false ~deadline:(Unix.gettimeofday () +. signal_grace) with
              | `Timeout -> ( try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ())
              | `Exited _ | `Signalled -> ());
              if not child.eof then Unix.close out;
              report Failed ("killed by " ^ signal_name s);
              Ok 1))

let%test_module "Tests" =
  (module struct
    open Test_fixture

    let knobs : Async_stream.knobs = { batch = 0.02; backoff_floor = 0.02; backoff_cap = 0.1 }

    let show_run ~dir run_id =
      match async_run ~dir ~knobs ~warn:(Printf.printf "\nwarning: %s") ~run_id with
      | Ok code -> Printf.printf "\n-> %d\n" code
      | Error m -> Printf.printf "\nrefused: %s\n" m

    let outcome ~dir (meta : Subrun.meta) =
      match Subrun.read_outcome ~dir meta.id with
      | None -> print_endline "no outcome"
      | Some o -> Printf.printf "outcome %s %S\n" (Subrun.string_of_result o.result) o.text

    let bash ?parent ~dir name command = run ~dir ~name ~kind:Bash ?parent ~command name

    (* Everything a parent needs is on disk by the time the wrapper returns, so a window that loses the
   remain-on-exit race costs only the corpse on screen: the command exits at once for that reason.
   Its exit code is the wrapper's, for #{pane_dead_status}. *)
    let%expect_test "the wrapper tees both streams, and records the ending before it returns" =
      let dir = Filename.temp_dir "kido-state" "" in
      List.iter
        (fun (name, command) ->
          let meta = bash ~dir name command in
          show_run ~dir name;
          outcome ~dir meta;
          Printf.printf "output file: %S\n"
            (Option.get_or ~default:"none" (Fs.read (Subrun.output_path ~dir meta.id))))
        [
          ("build", [ "sh"; "-c"; "printf out; printf err >&2; exit 3" ]);
          ("ok", [ "true" ]);
          ("killed", [ "sh"; "-c"; "kill -KILL $$" ]);
          ("missing", [ "no-such-command-kido" ]);
        ];
      [%expect
        {|
    outerr
    -> 3
    outcome failed "exit status 3"
    output file: "outerr"

    -> 0
    outcome completed "exit status 0"
    output file: ""

    -> 1
    outcome failed "signal: killed"
    output file: ""

    refused: exec: "no-such-command-kido": No such file or directory
    outcome failed "exec: \"no-such-command-kido\": No such file or directory"
    output file: ""
    |}]

    let%expect_test "the run comes from its record: a missing id or meta is refused" =
      let dir = Filename.temp_dir "kido-state" "" in
      show_run ~dir "";
      show_run ~dir "no-such-run";
      [%expect
        {|
    refused: --run-id is required (or $KIDO_AGENT_RUN_ID)
    usage: kido async-run [--run-id ID]

    refused: run no-such-run has no meta
    |}]

    (* The outcome write decides who saw the ending first: a wrapper finding one there keeps that story
   and sends nothing. The silence means something only beside the same wrapper, having won, trying
   to notify a parent that is gone and saying so. *)
    let%expect_test "a wrapper that loses the outcome race says nothing" =
      let dir = Filename.temp_dir "kido-state" "" in
      let parent = "nobody-alive-reports-this" in
      let lost = bash ~dir ~parent "raced" [ "true" ] in
      ignore (Subrun.record_outcome ~dir lost.id { result = Stopped; text = ""; at = None });
      show_run ~dir "raced";
      outcome ~dir lost;
      let _ = bash ~dir ~parent "won" [ "true" ] in
      show_run ~dir "won";
      [%expect
        {|
    -> 0
    outcome stopped ""

    warning: no live process holds session "nobody-alive-reports-this"; the parent is gone, nothing sent
    -> 0
    |}]

    (* The stream closes before the notice goes, so the notice follows the final chunk. *)
    let%expect_test "Stream meta sends the output as it runs, then the ending" =
      let dir = Filename.temp_dir "kido-state" "" in
      let inbox, received = start_inbox ~reply:"ok\n" in
      Result.get_exn (State.record ~dir "root-sess" (session ~pane:"%2" ~inbox ()));
      let _ =
        run ~dir ~kind:Stream ~parent:"root-sess" ~command:[ "printf"; "one\\ntwo\\nthree" ]
          "chatty"
      in
      show_run ~dir "chatty";
      (* However the lines were batched, every one is streamed before the notice. *)
      List.filter_map Test_fixture.envelope (received ())
      |> List.fold_left
           (fun (streamed, lines) e ->
             match e "kind" with
             | "stream" -> (streamed @ String.lines (e "text"), lines)
             | kind ->
                 ( streamed,
                   lines
                   @ [
                       Printf.sprintf "%s after [%s]: %s" kind (String.concat " " streamed)
                         (List.hd (String.lines (e "text")));
                     ] ))
           ([], [])
      |> snd |> List.iter print_endline;
      [%expect
        {|
    one
    two
    three
    -> 0
    notice after [one two three]: async run "chatty" completed: exit status 0
    |}]

    (* Being killed is exactly the ending nobody else is watching for. Run as its own process, since
   the signal is the wrapper's to catch. *)
    let%expect_test "a signalled wrapper passes the signal on, records the ending and exits 1" =
      let dir = Filename.temp_dir "kido-state" "" in
      let meta = bash ~dir "doomed" [ "sleep"; "30" ] in
      let wrapper =
        Unix.create_process_env "../bin/main.exe"
          [| "kido"; "async-run"; "--run-id"; "doomed" |]
          [| "KIDO_STATE_DIR=" ^ dir; "PATH=" ^ Sys.getenv "PATH" |]
          Unix.stdin Unix.stdout Unix.stderr
      in
      let output = Subrun.output_path ~dir meta.id in
      let deadline = Unix.gettimeofday () +. 5. in
      while (not (Sys.file_exists output)) && Float.(Unix.gettimeofday () < deadline) do
        Unix.sleepf 0.02
      done;
      Unix.kill wrapper Sys.sigterm;
      (match Unix.waitpid [] wrapper with
      | _, WEXITED code -> Printf.printf "exit %d\n" code
      | _ -> print_endline "not an exit");
      outcome ~dir meta;
      [%expect {|
    exit 1
    outcome failed "killed by terminated"
    |}]
  end)
