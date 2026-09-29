let usage = "usage: kido async-run [--run-id ID] [--stream]"
let signal_grace = 2.

(* Go's names, which the outcome text has always carried. *)
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

let async_run ~dir ~knobs ~run_id ~stream args =
  (match args with
  | [] -> ()
  | a :: _ ->
      Cli.failf
        "unknown argument %S; the command comes from the run's own record, not the command line\n%s"
        a usage);
  let id =
    match Subrun.parse_id run_id with
    | Ok id -> id
    | Error _ -> failwith ("--run-id is required (or $KIDO_AGENT_RUN_ID)\n" ^ usage)
  in
  let runs = Filename.concat dir "runs" in
  let meta =
    match Subrun.read_meta ~dir:runs id with
    | Some m -> m
    | None -> Cli.failf "run %s has no meta" run_id
  in
  let argv =
    match Subrun.read_command ~dir:runs id with
    | Some (_ :: _ as argv) -> argv
    | _ -> Cli.failf "run %s has no command" run_id
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
    Unix.openfile (Subrun.output_path ~dir:runs id) [ O_WRONLY; O_CREAT; O_TRUNC; O_CLOEXEC ] 0o644
  in
  let stream = if stream then Some (Async_stream.start ~dir knobs meta) else None in
  let report result text =
    let unstreamed = Option.map_or ~default:0 Async_stream.close stream in
    let outcome : Subrun.outcome = { result; text; at = Some (Timestamp.now ()) } in
    if Subrun.record_outcome ~dir:runs id outcome then
      Result.iter_err
        (fun e -> Cli.error "async-run" (Msg.string_of_error e))
        (Reap.send ~dir { meta; outcome; detail = Bash { unstreamed } })
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
          failwith why
      | pid -> (
          Unix.close out_w;
          let child = { pid; out; eof = false } in
          let buf = Bytes.create 65536 in
          let pump = pump ~file ~stream ~wake ~caught child buf in
          match pump ~watch:true ~deadline:Float.infinity with
          | `Exited status ->
              let result, text, code = status_of status in
              report result text;
              code
          | `Signalled | `Timeout ->
              let s = Option.get_exn_or "caught" (Atomic.get caught) in
              (try Unix.kill pid s with Unix.Unix_error _ -> ());
              ignore (pump ~watch:false ~deadline:(Unix.gettimeofday () +. signal_grace));
              if not child.eof then Unix.close out;
              report Failed ("killed by " ^ signal_name s);
              1))
