open Cmdliner
open Cmdliner.Term.Syntax
open Kido

let error name msg =
  Printf.eprintf "%s: %s\n%!" (if String.is_empty name then "kido" else "kido " ^ name) msg

let run name body =
  let fail msg =
    error name msg;
    1
  in
  match
    let code = body () in
    flush stdout;
    code
  with
  | code -> code
  (* sigpipe is ignored for the inbox sockets, so a closed stdout arrives as strerror(EPIPE) *)
  | exception Sys_error m when String.equal m (Unix.error_message Unix.EPIPE) ->
      Sys.set_signal Sys.sigpipe Sys.Signal_default;
      Unix.kill (Unix.getpid ()) Sys.sigpipe;
      1
  | exception Failure msg -> fail msg
  | exception Invalid_argument msg -> fail msg
  | exception Sys_error msg -> fail msg
  | exception Yojson.Json_error msg -> fail msg
  | exception Unix.Unix_error (e, fn, arg) -> fail (Fs.unix_message e fn arg)

let table rows =
  let width s = String.fold (fun n c -> if Char.code c land 0xC0 = 0x80 then n else n + 1) 0 s in
  let widths =
    List.fold_left
      (fun ws row -> List.map2 (fun w c -> max w (width c + 2)) ws row)
      (List.map (Fun.const 0) (List.hd rows))
      rows
  in
  List.iter
    (fun row ->
      let cells = List.combine widths row in
      List.iteri
        (fun i (w, c) ->
          print_string c;
          if i < List.length cells - 1 then print_string (String.make (w - width c) ' '))
        cells;
      print_newline ())
    rows

let local_time t =
  let whole = Float.of_int (Float.to_int t) in
  let tm = Unix.localtime whole and utc = Unix.gmtime whole in
  let days =
    match Int.compare tm.tm_year utc.tm_year with 0 -> tm.tm_yday - utc.tm_yday | c -> c
  in
  let offset =
    ((((((days * 24) + tm.tm_hour - utc.tm_hour) * 60) + tm.tm_min - utc.tm_min) * 60)
    + tm.tm_sec - utc.tm_sec)
    / 60
  in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d%s" (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec
    (if offset = 0 then "Z"
     else
       Printf.sprintf "%c%02d:%02d"
         (if offset < 0 then '-' else '+')
         (abs offset / 60)
         (abs offset mod 60))

let rest = Arg.(value & pos_all string [] & info [] ~docv:"ARG")
let str name docv doc = Arg.(value & opt string "" & info [ name ] ~docv ~doc)
let flag name doc = Arg.(value & flag & info [ name ] ~doc)
let arg docv = Arg.(required & pos 0 (some string) None & info [] ~docv)

let stdin () =
  let s = In_channel.input_all stdin in
  Option.get_or ~default:s (String.chop_suffix ~suf:"\n" s)

let cmd name doc term = Cmd.v (Cmd.info name ~doc) Term.(const (fun f -> run name f) $ term)
let ok = Result.get_or_failwith

let server_dir =
  Arg.(
    value
    & opt (some string) None
    & info [ "server" ] ~docv:"DIR"
        ~doc:"The kido server's state directory; its socket is DIR/socket.")

let state_dir () =
  let dir = Server_dir.dir () in
  ok (Server_dir.check_dir ~dir);
  dir

let self_pane () =
  Option.map Tmux.pane_id_of_string
    (Option.filter (Fun.negate String.is_empty) (Sys.getenv_opt "TMUX_PANE"))

let linger () =
  match Option.flat_map Int.of_string (Sys.getenv_opt "KIDO_LINGER_SECONDS") with
  | Some n when n > 0 -> Float.of_int n
  | _ -> 30.

let resolved_dir server = Fs.abs (Option.get_lazy Server_dir.dir server)

let session_for ~state s =
  let of_pane () =
    match self_pane () with
    | None -> Error "no caller pane; pass --session"
    | Some pane -> (
        match State.find state pane with
        | None ->
            Error (Printf.sprintf "pane %s is not on this server" (Tmux.string_of_pane_id pane))
        | Some p -> Ok p.session_id)
  in
  if String.is_empty s then of_pane ()
  else if String.prefix ~pre:"$" s then Ok (Tmux.session_id_of_string s)
  else
    match List.find_opt (fun (p : State.pane) -> String.equal p.session_name s) state.panes with
    | Some p -> Ok p.session_id
    | None -> Error (Printf.sprintf "no session named %S" s)

let start_run name parent name_arg cwd session envs command =
  let dir = state_dir () in
  match State.read ~dir (Tmux.create ()) with
  | Error e ->
      error name e;
      1
  | Ok state -> (
      match session_for ~state session with
      | Error e ->
          error name e;
          1
      | Ok session -> (
          match
            Run_window.start ?parent ~dir ~name:name_arg
              ~cwd:(if String.is_empty cwd then Sys.getcwd () else cwd)
              ~session ~env:envs command
          with
          | Ok c ->
              Printf.printf "{\"id\":%S,\"pane\":%S,\"output\":%S}\n" (Run.string_of_id c.meta.id)
                (Tmux.string_of_window_id c.window ^ "." ^ Tmux.string_of_pane_id c.pane)
                c.output;
              0
          | Error (Run_window.Refused_name m) ->
              error name m;
              4
          | Error (Run_window.Failed m) ->
              error name m;
              1))

let run_options =
  let+ name =
    Arg.(
      required
      & opt (some string) None
      & info [ "name" ] ~docv:"NAME" ~doc:"The window name; required.")
  and+ cwd = str "cwd" "DIR" "Working directory; defaults to the caller's."
  and+ session = str "session" "S" "tmux session id or name; defaults to the caller's."
  and+ env =
    Arg.(
      value & opt_all string []
      & info [ "env" ] ~docv:"K=V" ~doc:"A variable for the run's window; repeatable.")
  in
  (name, cwd, session, env)

let run_command =
  cmd "run" "Start a run in its own tmux window."
  @@ let+ name, cwd, session, env = run_options and+ command = rest in
     fun () ->
       if List.is_empty command then begin
         error "run"
           "no command given\n\
            usage: kido run --name N [--cwd D] [--session S] [--env K=V]... -- CMD...";
         1
       end
       else start_run "run" None name cwd session env command

let run_child =
  cmd "run-child" "Start a run under a parent run or pi pane."
  @@ let+ name, cwd, session, env = run_options and+ args = rest in
     fun () ->
       match args with
       | [] ->
           error "run-child"
             "no parent given\n\
              usage: kido run-child PARENT --name N [--cwd D] [--session S] [--env K=V]... -- \
              CMD...";
           1
       | [ _ ] ->
           error "run-child"
             "no command given\n\
              usage: kido run-child PARENT --name N [--cwd D] [--session S] [--env K=V]... -- \
              CMD...";
           1
       | parent :: command -> (
           let dir = state_dir () in
           match State.read ~dir (Tmux.create ()) with
           | Error e ->
               error "run-child" e;
               1
           | Ok state -> (
               match Run_window.resolve_parent ~dir ~state parent with
               | Error m ->
                   error "run-child" m;
                   2
               | Ok parent -> start_run "run-child" parent name cwd session env command))

let runs =
  cmd "runs" "List runs, or show one."
  @@ let+ json = flag "json" "Print JSON instead of a table."
     and+ parent =
       str "parent" "P"
         "Only runs under this parent: a run id, or the pane id %N of a top-level pi."
     and+ args = rest in
     fun () ->
       let dir = state_dir () in
       let state =
         Option.get_or ~default:State.empty (Result.to_opt (State.read ~dir (Tmux.create ())))
       in
       let parent =
         if String.is_empty parent then Ok None
         else Result.map (fun parent -> Some parent) (Run.parse_parent parent)
       in
       match parent with
       | Error m ->
           error "runs" m;
           2
       | Ok parent -> (
           match args with
           | [] ->
               let infos = Run_history.list ?parent ~dir ~state () in
               if json then
                 print_endline
                   (Yojson.Safe.to_string
                      (`List
                         (List.map
                            (fun (i : Run_history.info) -> Run_history.yojson_of_info i)
                            infos)))
               else begin
                 let now = Timestamp.now () in
                 table
                   ([ "ID"; "NAME"; "SESSION"; "PARENT"; "STARTED"; "DURATION"; "OUTCOME"; "CWD" ]
                   :: List.map
                        (fun ({ meta = m; outcome; session; _ } : Run_history.info) ->
                          let outcome, ended =
                            match outcome with
                            | None -> ("running", Some now)
                            | Some o -> (Run.string_of_result o.result, o.at)
                          in
                          [
                            Run.string_of_id m.id;
                            m.name;
                            Option.value ~default:"" session;
                            (match m.parent with
                            | Some (Run.Run x) -> Run.string_of_id x
                            | Some (Run.Pane p) -> Tmux.string_of_pane_id p
                            | None -> "");
                            local_time m.started_at;
                            (match ended with
                            | Some t -> Timestamp.duration (Float.round (t -. m.started_at))
                            | None -> "-");
                            outcome;
                            m.cwd;
                          ])
                        infos)
               end;
               0
           | [ id ] -> (
               match Run.parse_id id with
               | Error m ->
                   error "runs" m;
                   3
               | Ok id -> (
                   match Run_history.detail ~dir ~state id with
                   | Error m ->
                       error "runs" m;
                       3
                   | Ok d ->
                       let m = d.info.meta in
                       if json then
                         print_endline
                           (Yojson.Safe.to_string
                              (Yojson.Safe.Util.combine
                                 (Run_history.yojson_of_info d.info)
                                 (`Assoc
                                    (match d.screen with
                                    | Some s -> [ ("screen", `String s) ]
                                    | None -> []))))
                       else begin
                         let line k v = Printf.printf "%-10s%s\n" (k ^ ":") v in
                         line "id" (Run.string_of_id id);
                         line "name" m.name;
                         line "session" (Option.value ~default:"" d.info.session);
                         line "parent"
                           (match m.parent with
                           | Some parent -> Run.string_of_parent parent
                           | None -> "");
                         line "cwd" m.cwd;
                         line "started" (local_time m.started_at);
                         (match d.info.outcome with
                         | None -> line "outcome" "running"
                         | Some o ->
                             line "outcome" (Run.string_of_result o.result);
                             Option.iter (fun at -> line "ended" (local_time at)) o.at;
                             if not (String.is_empty o.text) then line "detail" o.text);
                         line "output" (Run.output_path ~dir m.id);
                         Option.iter (Printf.printf "screen:\n%s\n") d.screen
                       end;
                       0))
           | _ :: extra :: _ ->
               error "runs"
                 (Printf.sprintf
                    "unknown argument %S\nusage: kido runs [--json] [--parent P] [<run-id>]" extra);
               1)

let run_outcome =
  cmd "run-outcome" "Record a run's own outcome."
  @@ let+ result =
       Arg.(
         required
         & opt (some (enum [ ("completed", Run.Completed); ("failed", Failed) ])) None
         & info [ "result" ] ~docv:"RESULT" ~doc:"completed or failed.")
     and+ text = str "text" "TEXT" "Optional detail."
     and+ id = arg "RUN_ID" in
     fun () ->
       ok (Run.run_outcome ~dir:(state_dir ()) ~result ~text (ok (Run.parse_id id)));
       0

let run_wait =
  cmd "run-wait" "Wait for a run to end and print its outcome."
  @@ let+ json = flag "json" "Print the outcome object instead of its result."
     and+ id = arg "RUN_ID" in
     fun () ->
       match Run.parse_id id with
       | Error m ->
           error "run-wait" m;
           3
       | Ok id -> (
           match Run_wait.wait ~dir:(state_dir ()) id with
           | Error m ->
               error "run-wait" m;
               3
           | Ok outcome ->
               print_endline
                 (if json then Yojson.Safe.to_string (Run.yojson_of_outcome outcome)
                  else Run.string_of_result outcome.result);
               0)

let run_stop =
  cmd "run-stop" "Record a run's ending, then stop its process and close its pane."
  @@ let+ wait =
       Arg.(
         value & opt float 0.
         & info [ "wait" ] ~docv:"SECS"
             ~doc:"Seconds to wait for the run to end before signalling its process group.")
     and+ result =
       Arg.(
         value
         & opt (enum [ ("stopped", Run.Stopped); ("completed", Run.Completed) ]) Run.Stopped
         & info [ "result" ] ~docv:"RESULT" ~doc:"stopped or completed; default stopped.")
     and+ id = arg "RUN_ID" in
     fun () ->
       match Run.parse_id id with
       | Error m ->
           error "run-stop" m;
           3
       | Ok id -> (
           match
             Run_stop.stop ~dir:(state_dir ()) ~wait
               ~escalation:(Timestamp.ms_env Sys.getenv_opt "KIDO_STOP_ESCALATION_MS" 5.)
               ~result id
           with
           | Error (Run_stop.No_run m) ->
               error "run-stop" m;
               3
           | Error (Run_stop.Ended m) ->
               error "run-stop" m;
               5
           | Ok pane -> (
               match pane with
               | Run_stop.Killed ->
                   Printf.printf "stopped run %s; killed its pane\n" (Run.string_of_id id);
                   0
               | Run_stop.No_pane | Run_stop.Already_gone ->
                   Printf.printf "stopped run %s; its pane was already gone\n" (Run.string_of_id id);
                   0
               | Run_stop.Refused m ->
                   error "run-stop"
                     (Printf.sprintf
                        "run %s was recorded stopped, but its pane could not be killed: %s"
                        (Run.string_of_id id) m);
                   1))

let prompt =
  cmd "prompt" "Send a prompt, read from stdin, to the agent in the caller's window or session."
  @@ let+ window =
       flag "window" "Search only the caller's window, never widening to the session."
     in
     fun () ->
       let refuse why code =
         prerr_endline why;
         code
       in
       match Prompt.prompt ~dir:(state_dir ()) ~self:(self_pane ()) ~window (stdin ()) with
       | Ok () -> 0
       | Error No_prompt -> refuse "no prompt given" 1
       | Error Not_found -> refuse "agent not found" 4
       | Error Several -> refuse "multiple agents found" 5
       | Error (Failed m) -> failwith m

let switch name doc kind =
  cmd name doc
  @@ let+ next =
       Arg.(
         required
         & pos 0 (some (enum [ ("next", true); ("prev", false) ])) None
         & info [] ~docv:"next|prev")
     and+ client = str "client" "NAME" "tmux client to switch; defaults to $(b,TMUX_SIDE_CLIENT)."
     and+ server = server_dir in
     fun () ->
       let dir = resolved_dir server in
       let tmux = Tmux.create ~socket:(ok (Server_dir.server_socket ~create:false ~dir)) () in
       let client =
         List.find_opt (fun c -> not (String.is_empty c)) [ client; Fs.getenv "TMUX_SIDE_CLIENT" ]
         |> Option.get_lazy (fun () ->
             Result.get_or ~default:""
               (Tmux.exec tmux [ "display-message"; "-p"; "#{client_name}" ]))
       in
       let direction = if next then Sidebar.Next else Sidebar.Prev in
       let request =
         match kind with
         | `Session -> Sidebar.Switch_session direction
         | `Window -> Sidebar.Switch_window direction
       in
       ignore (ok (Sidebar.handle ~tmux ~dir ~client request));
       0

let switch_session =
  switch "switch-session" "Switch the client to the next or previous session." `Session

let switch_window =
  switch "switch-window" "Switch the client to the next or previous window." `Window

let server =
  cmd "server" "Start the kido server detached unless it is running, and print its tmux and socket."
  @@ let+ server = server_dir in
     fun () ->
       print_endline
         (Yojson.Safe.to_string
            (Launch.yojson_of_endpoint
               (ok (Launch.ensure ~dir:(resolved_dir server) ~env:(Unix.environment ())))));
       0

let shell =
  Cmd.v (Cmd.info "shell" ~doc:"Exec the pane's login shell, primed with kido's shell integration.")
  @@ let+ () = Term.const () in
     run "shell" (fun () ->
         ignore (state_dir ());
         Shell.run ())

let ssh =
  Cmd.v (Cmd.info "ssh" ~doc:"Run ssh, priming the remote login shell when it can.")
  @@ let+ args = rest in
     run "ssh" (fun () ->
         let path = Fs.getenv "PATH" in
         let ssh =
           match Bin_dir.own () with
           | Some dir ->
               Bin_dir.look_path_past ~path ~dir "ssh"
               |> Option.get_lazy (fun () -> failwith ("no ssh on PATH past " ^ dir))
           | None ->
               Fs.look_path ~path "ssh"
               |> Option.get_lazy (fun () ->
                   failwith {|exec: "ssh": executable file not found in $PATH|})
         in
         let tty =
           match Unix.fstat Unix.stdin with
           | st -> Stdlib.(st.st_kind = S_CHR)
           | exception Unix.Unix_error _ -> false
         in
         let argv = Ssh.prepare ~ssh ~tty ~pane:(self_pane ()) args in
         Unix.execve ssh (Array.of_list argv) (Unix.environment ()))

(* Go's time.Duration syntax, which every caller of --interval already speaks: "100ms", "5s",
   "1m30s". *)
let parse_duration s =
  let units =
    [ ("ns", 1e-9); ("us", 1e-6); ("µs", 1e-6); ("ms", 1e-3); ("s", 1.); ("m", 60.); ("h", 3600.) ]
  in
  let rec go i acc =
    if i >= String.length s then if i = 0 then Error "empty duration" else Ok acc
    else
      let j = ref i in
      while !j < String.length s && (Char.Ascii.is_digit s.[!j] || Char.equal s.[!j] '.') do
        incr j
      done;
      match Float.of_string_opt (String.sub s i (!j - i)) with
      | None -> Error (Printf.sprintf "invalid duration %S" s)
      | Some n -> (
          match List.find_opt (fun (u, _) -> String.prefix ~pre:u (String.drop !j s)) units with
          | None -> Error (Printf.sprintf "missing unit in duration %S" s)
          | Some (u, f) -> go (!j + String.length u) (acc +. (n *. f)))
  in
  go 0 0.

let duration =
  Arg.conv
    ( (fun s -> Result.map_err (fun e -> `Msg e) (parse_duration s)),
      fun ppf d -> Format.fprintf ppf "%gs" d )

let reap =
  Cmd.v (Cmd.info "reap" ~doc:"Close the finished subagent windows a sweep names.")
  @@ let+ args = rest in
     run "reap" (fun () ->
         if not (List.is_empty args) then failwith "usage: kido reap";
         let dir = state_dir () in
         let tmux = Tmux.create () in
         Reap.collect tmux ~dir ~grace:(linger ())
           (ok (State.read ~dir tmux))
           ~now:(Unix.gettimeofday ());
         0)

(* The fork sets TMUX_SIDE_CLIENT only for the side-status-command job, so its absence is exactly
   "not started as a side column". *)
let sidebar =
  let+ server = server_dir
  and+ interval =
    Arg.(
      value
      & opt duration Sidebar.default_interval
      & info [ "interval" ] ~docv:"DURATION"
          ~doc:"Refresh interval; tmux changes also refresh immediately.")
  and+ client =
    Arg.(
      value
      & opt (some string) None
      & info [ "client" ] ~docv:"NAME"
          ~doc:
            "tmux client to act on; defaults to $(b,TMUX_SIDE_CLIENT), and is required without it.")
  in
  let side = Fs.getenv "TMUX_SIDE_CLIENT" in
  let env = Sys.getenv_opt "TMUX" in
  let inside = Option.flat_map Tmux.env_of_string env in
  match (Sys.argv, side, env) with
  | _, "", _ when Array.length Sys.argv = 1 || Option.is_some server ->
      run "" (fun () ->
          match Launch.run ~dir:(resolved_dir server) ~env:(Unix.environment ()) ~inside with
          | Ok _ -> 0
          | Error m -> failwith m)
  | _, _, None ->
      error "" "must run inside tmux";
      1
  | _, _, Some _ ->
      run "" (fun () ->
          let dir = state_dir () in
          let tmux = Tmux.create () in
          let client =
            match client with
            | Some c when not (String.is_empty c) -> Some c
            | _ when not (String.is_empty side) -> Some side
            | _ ->
                Sidebar.resolve_client tmux ~pane:(self_pane ())
                  ~session:(Option.flat_map (fun (e : Tmux.env) -> e.session) inside)
          in
          match client with
          | None ->
              error "" "no tmux client; pass --client '#{client_name}'";
              1
          | Some client ->
              Kido_sidebar.run ~standalone:(String.is_empty side)
                { interval; client; tmux; dir; grace = linger () };
              0)

type input = Line of string | Eof | Read_error of string

let rpc =
  cmd "rpc" "Stream the sidebar's rows to a native sidebar, as one JSON line per change."
  @@ let+ server = server_dir
     and+ client = str "client" "NAME" "The tmux client the rows are drawn for." in
     fun () ->
       if String.is_empty client then failwith "usage: kido rpc [--server DIR] --client NAME";
       let dir = resolved_dir server in
       let socket = ok (Server_dir.server_socket ~create:false ~dir) in
       if not (Sys.file_exists socket) then Printf.ksprintf failwith "no tmux server at %s" socket;
       let write line =
         print_endline line;
         flush stdout
       in
       let stamp =
         match Launch.probe_server ~socket (Lazy.force Tmux.binary) with
         | Up stamp -> stamp
         | Down | Mismatch -> None
       in
       write (Yojson.Safe.to_string (Protocol.hello ~expected:Launch.stamp stamp));
       if not (Protocol.matches ~expected:Launch.stamp stamp) then (
         write
           (Yojson.Safe.to_string
              (`Assoc [ ("error", `String "server stamp does not match binary stamp") ]));
         2)
       else
         let opts =
           {
             Sidebar.interval = Sidebar.default_interval;
             client;
             tmux = Tmux.create ~socket ();
             dir;
             grace = linger ();
           }
         in
         let lock = Mutex.create () and input = Queue.create () in
         let push i = Mutex.protect lock (fun () -> Queue.push i input) in
         let rec read () =
           match In_channel.input_line Stdlib.stdin with
           | Some line ->
               push (Line line);
               read ()
           | None -> push Eof
           | exception Sys_error e -> push (Read_error e)
         in
         ignore (Thread.create read ());
         let conn = Tmux.Client.connect opts.tmux ~client in
         let rec loop ?wait (m : Sidebar.model) last =
           let snap = Sidebar.poll ?wait ~opts conn m.snap in
           if Option.is_none snap.client then
             Printf.ksprintf failwith "no tmux client %S on %s" client socket;
           let m, changed = Sidebar.step m snap in
           let inputs =
             Mutex.protect lock (fun () ->
                 let l = List.of_seq (Queue.to_seq input) in
                 Queue.clear input;
                 l)
           in
           List.iter
             (function
               | Line l -> (
                   match Protocol.decode l with
                   | Request (id, Any request) -> (
                       try
                         let response =
                           Sidebar.handle ~tmux:opts.tmux ~dir:opts.dir ~client:opts.client request
                         in
                         write (Yojson.Safe.to_string (Protocol.reply id request response))
                       with
                       | Sys_error e -> write (Yojson.Safe.to_string (Protocol.error id e))
                       | Unix.Unix_error (e, fn, arg) ->
                           write
                             (Yojson.Safe.to_string (Protocol.error id (Fs.unix_message e fn arg))))
                   | Invalid (id, error) -> write (Yojson.Safe.to_string (Protocol.error id error))
                   | Ignored -> ())
               | Eof | Read_error _ -> ())
             inputs;
           let last =
             if not changed then last
             else
               match Protocol.snapshot m with
               | Some json ->
                   let line = Yojson.Safe.to_string json in
                   if not (String.equal line last) then write line;
                   line
               | None -> last
           in
           match
             List.find_map
               (function Eof -> Some None | Read_error e -> Some (Some e) | Line _ -> None)
               inputs
           with
           | Some None -> 0
           | Some (Some e) -> failwith e
           | None -> loop ~wait:opts.interval m last
         in
         Fun.protect
           ~finally:(fun () -> Tmux.Client.close conn)
           (fun () -> loop (Sidebar.make ~now:Unix.gettimeofday opts) "")

let () =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let cmd =
    Cmd.group ~default:sidebar
      (Cmd.info "kido" ~version:Build_id.value)
      [
        server;
        run_command;
        run_child;
        run_stop;
        runs;
        run_outcome;
        run_wait;
        prompt;
        switch_session;
        switch_window;
        shell;
        ssh;
        reap;
        rpc;
      ]
  in
  (* ssh's arguments are ssh's own, options included. *)
  let argv =
    match Array.to_list Sys.argv with
    | k :: "ssh" :: rest -> Array.of_list (k :: "ssh" :: "--" :: rest)
    | _ -> Sys.argv
  in
  exit
    (match Cmd.eval_value ~catch:false ~argv cmd with
    | Ok (`Ok code) -> code
    | Ok (`Help | `Version) -> 0
    | Error _ -> 1)
