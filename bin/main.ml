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

let held_message id (s : Run.pi) =
  Printf.sprintf "session %s is already open in pane %s (pid %d); this process is not tracked" id
    (match s.pane with Some x -> Tmux.string_of_pane_id x | None -> "")
    s.pid

let rest = Arg.(value & pos_all string [] & info [] ~docv:"ARG")
let str name docv doc = Arg.(value & opt string "" & info [ name ] ~docv ~doc)
let flag name doc = Arg.(value & flag & info [ name ] ~doc)
let arg docv = Arg.(required & pos 0 (some string) None & info [] ~docv)

let address docv =
  Term.(const (fun s -> Option.get_or ~default:s (String.chop_prefix ~pre:"@" s)) $ arg docv)

let stdin () =
  let s = In_channel.input_all stdin in
  Option.get_or ~default:s (String.chop_suffix ~suf:"\n" s)

let cmd ?(group = "") name doc term =
  Cmd.v (Cmd.info name ~doc) Term.(const (fun f -> run (group ^ name) f) $ term)

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

let env_run_id name =
  Option.map
    (fun s -> ok (Run.parse_id s))
    (Option.filter (Fun.negate String.is_empty) (Sys.getenv_opt name))

let caller dir =
  let open Option.Infix in
  let* id = Result.to_opt (Run.parse_id (Fs.getenv "PI_SESSION_ID")) in
  let+ pi = Run.read_pi ~dir id in
  (id, pi)

let stall_threshold () = Timestamp.ms_env Sys.getenv_opt "KIDO_STALL_THRESHOLD_MS" 180.

(* The same knob share/pi/kido-agents.ts reads. *)
let linger () =
  match Option.flat_map Int.of_string (Sys.getenv_opt "KIDO_LINGER_SECONDS") with
  | Some n when n > 0 -> Float.of_int n
  | _ -> 30.

let resolved_dir server = Fs.abs (Option.get_lazy Server_dir.dir server)

let print r =
  print_endline (ok r);
  0

let sent = function
  | Ok line ->
      print_endline line;
      0
  | Error Message_agent.No_text ->
      prerr_endline "no message given";
      1
  | Error (Not_sent m) -> failwith m

let send name doc spec =
  cmd ~group:"tool " name doc
  @@ let+ recipient, spec = spec in
     fun () ->
       let dir = state_dir () in
       sent
         (Message_agent.send ~dir ~self:(self_pane ()) ~caller:(caller dir) recipient spec
            (stdin ()))

let message_agent =
  send "message_agent" "Send a message to another agent, read from stdin."
  @@ let+ reply_to = str "reply-to" "ID" "Id of an earlier ask this message answers."
     and+ to_ = address "TO" in
     ( Message_agent.Named to_,
       if String.is_empty reply_to then Message_agent.Message else Message_agent.Reply reply_to )

let ask_agent =
  send "ask_agent" "Ask another agent a question, read from stdin; its answer comes as a reply."
  @@ let+ id = str "id" "ID" "Id to assign this envelope; a fresh one is generated if omitted."
     and+ to_ = address "TO" in
     (Message_agent.Named to_, Message_agent.Ask (if String.is_empty id then None else Some id))

let steer_subagent =
  send "steer_subagent" "Steer a descendant agent mid-turn with a message read from stdin."
  @@ let+ to_ = address "AGENT" in
     (Message_agent.Descendant to_, Message_agent.Steer)

let interrupt_subagent =
  cmd ~group:"tool " "interrupt_subagent" "Abort a descendant agent's current turn."
  @@ let+ to_ = address "AGENT" in
     fun () ->
       let dir = state_dir () in
       print (Control.interrupt ~dir ~self:(self_pane ()) ~caller:(caller dir) to_)

let stop_run =
  cmd ~group:"tool " "stop_run" "Stop a descendant agent, or an async run."
  @@ let+ force =
       flag "force" "Kill the target's window directly when it has no inbox to ask nicely over."
     and+ to_ = address "RUN" in
     fun () ->
       let dir = state_dir () in
       print
         (Control.stop ~dir ~self:(self_pane ()) ~caller:(caller dir)
            ~escalation:(Timestamp.ms_env Sys.getenv_opt "KIDO_STOP_ESCALATION_MS" 5.)
            ~warn:(error "tool stop_run") ~force to_)

let runs =
  cmd "runs" "List subagent and async runs, or show one."
  @@ let+ json = flag "json" "Print JSON instead of a table." and+ args = rest in
     fun () ->
       let dir = state_dir () in
       match args with
       | [] ->
           let infos = Run_history.list ~dir () in
           if json then
             print_endline
               (Yojson.Safe.to_string (`List (List.map Run_history.yojson_of_info infos)))
           else begin
             let now = Timestamp.now () in
             table
               ([ "ID"; "NAME"; "PARENT"; "STARTED"; "DURATION"; "OUTCOME"; "CWD" ]
               :: List.map
                    (fun ({ meta = m; outcome } : Run_history.info) ->
                      let outcome, ended =
                        match outcome with
                        | None -> ("running", Some now)
                        | Some o -> (Run.string_of_result o.result, o.at)
                      in
                      [
                        Run.string_of_id m.id;
                        m.name;
                        (match m.parent with Some x -> Run.string_of_id x | None -> "");
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
       | [ id ] ->
           let d = ok (Run_history.detail ~dir (ok (Run.parse_id id))) in
           let m = d.info.meta in
           let cd = "cd " ^ Filename.quote m.cwd ^ " && " in
           let resume =
             cd
             ^
             match m.kind with
             | Pi -> (
                 "pi --session "
                 ^
                 match Run.read_pi ~dir m.id with
                 | Some (p : Run.pi) -> Filename.quote p.session_file
                 | None -> id)
             | Agent | Bash | Stream -> "kido tool spawn_subagent --resume " ^ id
           and fork = cd ^ "pi --fork " ^ id in
           if json then
             print_endline
               (Yojson.Safe.to_string
                  (Yojson.Safe.Util.combine
                     (Run_history.yojson_of_info d.info)
                     (`Assoc
                        ([
                           ("task", `String d.task);
                           ("resume", `String resume);
                           ("fork", `String fork);
                         ]
                        @ match d.screen with Some s -> [ ("screen", `String s) ] | None -> []))))
           else begin
             let line k v = Printf.printf "%-10s%s\n" (k ^ ":") v in
             line "id" id;
             line "name" m.name;
             line "kind" (Run.string_of_kind m.kind);
             line "parent" (match m.parent with Some x -> Run.string_of_id x | None -> "");
             line "cwd" m.cwd;
             if not (String.is_empty m.model) then line "model" m.model;
             if not (List.is_empty m.tools) then line "tools" ("[" ^ String.concat " " m.tools ^ "]");
             line "started" (local_time m.started_at);
             (match d.info.outcome with
             | None -> line "outcome" "running"
             | Some o ->
                 line "outcome" (Run.string_of_result o.result);
                 Option.iter (fun at -> line "ended" (local_time at)) o.at;
                 if not (String.is_empty o.text) then line "detail" o.text);
             Option.iter (line "report") d.report;
             line "resume" resume;
             line "fork" fork;
             Printf.printf "task:\n%s\n" d.task;
             Option.iter (Printf.printf "screen:\n%s\n") d.screen
           end;
           0
       | _ :: extra :: _ ->
           Printf.ksprintf failwith "unknown argument %S\nusage: kido runs [--json] [<run-id>]"
             extra

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
       ok
         (Run_ending.run_outcome ~dir:(state_dir ()) ~warn:(error "run-outcome") ~result ~text
            (ok (Run.parse_id id)));
       0

let async_run =
  cmd "async-run" "Run an async run's command, recording and reporting how it ended."
  @@ let+ run_id =
       str "run-id" "ID" "The run this window is running; defaults to $(b,KIDO_AGENT_RUN_ID)."
     in
     fun () ->
       ok
         (Async_run.async_run ~dir:(state_dir ())
            ~knobs:(Async_stream.knobs Sys.getenv_opt)
            ~warn:(error "async-run")
            ~id:
              (Run.parse_id
                 (if String.is_empty run_id then Fs.getenv "KIDO_AGENT_RUN_ID" else run_id)
              |> Result.map_err (fun _ ->
                  "--run-id is required (or $KIDO_AGENT_RUN_ID)\n\
                   usage: kido async-run [--run-id ID]")
              |> ok))

let notify_parent =
  cmd ~group:"tool " "notify_parent" "Send this subagent's report, read from stdin, to its parent."
  @@ let+ status = flag "status" "This notice is the child's status, not a report of its work." in
     fun () ->
       let dir = state_dir () in
       sent
         (Message_agent.notify_parent ~dir ~self:(self_pane ()) ~caller:(caller dir)
            ~warn:(error "tool notify_parent")
            ~parent:(env_run_id "KIDO_AGENT_PARENT_SESSION")
            ~run:(env_run_id "KIDO_AGENT_RUN_ID") ~status (stdin ()))

let list_runs =
  cmd ~group:"tool " "list_runs" "List peers, the caller's parent and its own agent and bash runs."
  @@ let+ session =
       str "session" "ID" "tmux session id to list; defaults to the caller's own session."
     and+ json = flag "json" "Print JSON instead of a table." in
     fun () ->
       let session =
         if String.is_empty session then None else Some (Tmux.session_id_of_string session)
       in
       let dir = state_dir () in
       let state = ok (State.read ~dir (Tmux.create ())) in
       let rows =
         List_runs.list_runs ~dir ~threshold:(stall_threshold ()) ~self:(self_pane ())
           ~caller:(Option.map fst (caller dir))
           ~session ~state
         |> Result.map_err (fun e -> e ^ "\nusage: kido tool list_runs [--session ID] [--json]")
         |> ok |> List.map List_runs.yojson_of_row
       in
       if json then print_endline (Yojson.Safe.to_string (`List rows))
       else begin
         let words = String.split_on_char ' ' in
         let columns =
           words
             "id name kind relationship status activity canReply model pane window stalled \
              sinceReport parent depth cwd run state startedAt"
         in
         let value json k =
           match Yojson.Safe.Util.member k json with
           | `String s -> s
           | `Int n -> string_of_int n
           | `Bool b -> string_of_bool b
           | _ -> ""
         in
         table
           (words
              "ID NAME KIND RELATIONSHIP STATUS ACTIVITY CAN_REPLY MODEL PANE WINDOW STALLED SINCE \
               PARENT DEPTH CWD RUN STATE STARTED OUTCOME DETAIL"
           :: List.map
                (fun json ->
                  List.map (value json) columns
                  @
                  match Yojson.Safe.Util.member "outcome" json with
                  | `Null -> [ ""; "" ]
                  | o -> List.map (value o) [ "result"; "text" ])
                rows)
       end;
       0

let set_status =
  cmd ~group:"tool " "set_status" "Set this agent's activity; an empty one clears it."
  @@ let+ activity = arg "ACTIVITY" in
     fun () ->
       let dir = state_dir () in
       match caller dir with
       | None ->
           failwith
             "no agent session is calling ($PI_SESSION_ID names none); there is nothing to set an \
              activity on"
       | Some (id, s) -> (
           match Reporting.set_activity ~dir (id, s) activity with
           | Ok () -> 0
           | Error holder -> failwith (held_message (Run.string_of_id id) holder))

let set_asks =
  cmd ~group:"tool " "set_asks" "Set the complete user ask list, read as JSON from stdin."
  @@ let+ () = Term.const () in
     fun () ->
       let dir = state_dir () in
       let id, _ =
         ok (Ask.caller ~dir (caller dir))
         |> Option.to_result "no agent session is calling ($PI_SESSION_ID names none)"
         |> ok
       in
       let asks =
         try Ask.entries_of_yojson (Yojson.Safe.from_string (stdin ()))
         with Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error (e, _) ->
           failwith (Printexc.to_string e)
       in
       let result = ok (Ask.set ~dir ~session:id ~asks ~now:(Timestamp.now ())) in
       print_endline (Yojson.Safe.to_string (`List (List.map Ask.yojson_of_answer result)));
       0

let remove_ask =
  cmd "remove-ask" "Remove an open user ask."
  @@ let+ id = arg "ID" in
     fun () ->
       let dir = state_dir () in
       let self = ok (Ask.caller ~dir (caller dir)) in
       ok (Ask.remove ~dir ~self:(Option.map fst self) (ok (Ask.parse_id id)));
       0

let get_asks =
  cmd "get-asks" "Print open user asks as JSON."
  @@ let+ session =
       Arg.(
         value
         & opt (some string) None
         & info [ "session" ] ~docv:"ID" ~doc:"Only asks from this session.")
     in
     fun () ->
       let dir = state_dir () in
       let asks =
         Ask.list ~dir
         |> List.filter_map (fun (a : Ask.t) ->
             if Option.for_all (String.equal (Run.string_of_id a.session)) session then
               Some (a, Run.load ~dir a.session)
             else None)
       in
       let state =
         if List.exists (fun (_, r) -> Option.is_some (Option.flat_map Run.holder r)) asks then
           ok (State.read ~dir (Tmux.create ()))
         else State.empty
       in
       print_endline
         (Yojson.Safe.to_string (`List (List.map (fun (a, r) -> Ask.to_json ~state a r) asks)));
       0

let get_agent =
  cmd "get-agent" "Print an agent session's liveness as JSON."
  @@ let+ session = Arg.(value & pos 0 string "" & info [] ~docv:"SESSION")
     and+ context = flag "context" "Print the live agent graph for internal message validation." in
     fun () ->
       let dir = state_dir () in
       if context then begin
         let state = ok (State.read ~dir (Tmux.create ())) in
         let agents =
           ok
             (List_runs.agents ~dir ~threshold:(stall_threshold ()) ~self:(self_pane ())
                ~caller:(Option.map fst (caller dir))
                ~session:None ~state)
         in
         print_endline
           (Yojson.Safe.to_string (`List (List.map List_runs.yojson_of_agent_info agents)));
         0
       end
       else begin
         if String.is_empty session then failwith "usage: kido get-agent SESSION";
         let id = Result.to_opt (Run.parse_id session) in
         print_endline
           (Yojson.Safe.to_string
              (`Assoc
                 [
                   ("id", `String session);
                   ( "alive",
                     `Bool (Option.exists (fun id -> Option.is_some (Run.live_pi ~dir id)) id) );
                 ]));
         0
       end

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

let created name f = run name (fun () -> print (f ()))

let spawn_subagent =
  Cmd.v (Cmd.info "spawn_subagent" ~doc:"Spawn a subagent in its own tmux window, or resume one.")
  @@ let+ name = str "name" "NAME" "Window name, and (by convention) the child's own --name."
     and+ task_file =
       str "task-file" "FILE"
         "File holding the task text to deliver as the child's first message, or - for stdin."
     and+ model =
       str "model" "M" "Model the child will run, recorded in the run's meta for kido runs."
     and+ tools =
       Arg.(
         value
         & opt (some string) None
         & info [ "tools" ] ~docv:"T,..."
             ~doc:
               "Comma-separated pi tool allowlist. On resume, omit to keep the stored list; pass \
                an empty value for pi defaults.")
     and+ resume =
       str "resume" "RUN_ID" "Resume an existing run's own session instead of starting a new one."
     and+ fork =
       str "fork" "SESSION_ID"
         "Seed the child's session with this pi session's transcript, so it starts holding the \
          caller's context."
     and+ no_parent =
       flag "no-parent"
         "Spawn with no parent edge at all: the child reports to nobody and is never reaped as an \
          orphan."
     and+ command = rest in
     created "tool spawn_subagent" (fun () ->
         let dir = state_dir () in
         Result.flat_map
           (Spawn_subagent.spawn ~dir ~self:(self_pane ()) ~caller:(caller dir)
              ~path:(Fs.getenv "PATH"))
           (Result.map_err (function
              | Spawn_subagent.Invalid why -> why
              | Usage why ->
                  why
                  ^ "\n\
                     usage: kido tool spawn_subagent [--no-parent] --name NAME --task-file FILE|- \
                     [--fork SESSION_ID] [--model M] [--tools T,...] [-- COMMAND...]\n\
                    \   or: kido tool spawn_subagent --resume RUN_ID [--no-parent] [--tools T,...] \
                     [-- COMMAND...]")
           @@ Spawn_subagent.parse
                { name; task_file; model; tools; resume; fork; no_parent; command }))

let async_bash =
  Cmd.v (Cmd.info "async_bash" ~doc:"Run a command in the background, in its own tmux window.")
  @@ let+ name = str "name" "NAME" "Window name; derived from the command when omitted."
     and+ stream = flag "stream" "Send the command's output to this caller in batches as it runs."
     and+ args = rest in
     created "tool async_bash" (fun () ->
         match args with
         | [] ->
             failwith
               "no command given\n\
                usage: kido tool async_bash [--name NAME] [--stream] -- COMMAND [ARG...]"
         | command :: rest ->
             let dir = state_dir () in
             Async_bash.async_bash ~dir ~self:(self_pane ())
               ~caller:(Option.map fst (caller dir))
               ~exe:(Lazy.force Fs.self) ~name ~stream (command, rest))

let agent_status =
  Cmd.v
    (Cmd.info "agent-status"
       ~doc:
         "Claim and report the run of the pi session $(b,PI_SESSION_ID), whose session file is \
          $(b,PI_SESSION_FILE).")
  @@ let+ inbox =
       str "inbox" "PATH"
         "Path of the unix socket the agent takes prompts on, speaking kido's own protocol (see \
          $(b,kido get-inbox)); empty means none."
     and+ activity =
       str "activity" "TEXT"
         "Free text describing what the agent is doing, one line of at most 256 bytes."
     and+ name = str "name" "NAME" "The pi session name, empty for an unnamed session."
     and+ model = str "model" "NAME" "Name of the model the agent is currently running."
     and+ remove = flag "remove" "Release the run: its record stays, held by no process." in
     run "agent-status" (fun () ->
         let dir = state_dir () in
         let session = Fs.getenv "PI_SESSION_ID" in
         let id = ok (Run.parse_id session) in
         match
           if remove then Run.release ~dir id ~holder:(Unix.getppid ())
           else
             Reporting.agent_status ~dir ~pane:(self_pane ()) ~id
               ~session_file:(Fs.getenv "PI_SESSION_FILE") ~inbox ~activity ~model ~name
         with
         | Ok () -> 0
         | Error holder ->
             error "agent-status" (held_message session holder);
             6)

let server =
  cmd "server" "Start the kido server detached unless it is running, and print its tmux and socket."
  @@ let+ server = server_dir in
     fun () ->
       print_endline
         (Yojson.Safe.to_string
            (Launch.yojson_of_endpoint
               (ok (Launch.ensure ~dir:(resolved_dir server) ~env:(Unix.environment ())))));
       0

let get_inbox =
  cmd "get-inbox" "Print an agent process's inbox socket path as JSON."
  @@ let+ pid = Arg.(required & pos 0 (some int) None & info [] ~docv:"PID") in
     fun () ->
       let path = ok (Msg.inbox_path ~dir:(state_dir ()) (Int.to_string pid)) in
       print_endline (Yojson.Safe.to_string (`Assoc [ ("path", `String path) ]));
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
                { interval; client; tmux; dir; threshold = stall_threshold (); grace = linger () };
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
             threshold = stall_threshold ();
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

let tool =
  Cmd.group
    (Cmd.info "tool" ~doc:"Agent tools.")
    [
      message_agent;
      ask_agent;
      set_asks;
      notify_parent;
      steer_subagent;
      interrupt_subagent;
      stop_run;
      list_runs;
      set_status;
      spawn_subagent;
      async_bash;
    ]

let () =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let cmd =
    Cmd.group ~default:sidebar
      (Cmd.info "kido" ~version:Build_id.value)
      [
        agent_status;
        server;
        get_inbox;
        tool;
        runs;
        run_outcome;
        async_run;
        get_agent;
        get_asks;
        remove_ask;
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
