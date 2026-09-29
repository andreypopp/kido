open Cmdliner
open Cmdliner.Term.Syntax
open Kido

let rest = Arg.(value & pos_all string [] & info [] ~docv:"ARG")
let str name docv doc = Arg.(value & opt string "" & info [ name ] ~docv ~doc)
let num name docv doc = Arg.(value & opt int 0 & info [ name ] ~docv ~doc)
let flag name doc = Arg.(value & flag & info [ name ] ~doc)

let hook =
  Cmd.v (Cmd.info "hook" ~doc:"Record a Claude Code hook event read from stdin.")
  @@ let+ args = rest in
     Cli.run ~failure:0 "hook" (fun () -> Reporting.hook args)

let agent_status =
  Cmd.v (Cmd.info "agent-status" ~doc:"Report the status of an agent session.")
  @@ let+ agent = str "agent" "NAME" "Name of the reporting agent, e.g. pi."
     and+ session = str "session" "ID" "The agent's session id; one state file per session."
     and+ status = str "status" "STATUS" "One of running, waiting, compacting or idle."
     and+ title = str "title" "TITLE" "The session's name, shown as the pane's label."
     and+ inbox =
       str "inbox" "PATH"
         "Path of the unix socket the agent takes prompts on, speaking kido's own protocol (see \
          $(b,kido inbox-path)); empty means none."
     and+ activity =
       str "activity" "TEXT"
         "Free text describing what the agent is doing, one line of at most 256 bytes."
     and+ parent_pid =
       num "parent-pid" "PID" "Pid of the agent that spawned this one, 0 for a root agent."
     and+ parent_session =
       str "parent-session" "ID"
         "Session id of the agent that spawned this one, empty for a root agent."
     and+ depth = num "depth" "N" "Depth in the spawn tree, 0 for a root agent."
     and+ model = str "model" "NAME" "Name of the model the agent is currently running."
     and+ ended = flag "ended" "A turn just finished."
     and+ remove = flag "remove" "Delete the session's record."
     and+ args = rest in
     Cli.run "agent-status" (fun () ->
         Reporting.agent_status ~agent ~session ~status ~title ~inbox ~activity ~parent_pid
           ~parent_session ~depth ~model ~ended ~remove args)

let debug_log =
  Cmd.v (Cmd.info "debug-log" ~doc:"Print the path of the hook debug log.")
  @@ let+ () = Term.const () in
     print_endline (Filename.concat (State.dir ()) "debug.log");
     0

let inbox_path =
  Cmd.v (Cmd.info "inbox-path" ~doc:"Print, and create the directory of, an agent's inbox socket.")
  @@ let+ args = rest in
     match args with
     | [ name ] ->
         Cli.run "inbox-path" (fun () ->
             print_endline (Msg.inbox_path ~dir:(State.dir ()) name);
             0)
     | _ ->
         prerr_endline "usage: kido inbox-path NAME";
         1

let duration =
  Arg.conv
    ( (fun s -> Result.map_err (fun e -> `Msg e) (Ui.parse_duration s)),
      fun ppf d -> Format.fprintf ppf "%gs" d )

let release_ops = { Reap.kill_window = Tmux.Exec.kill_window; kill_pane = Tmux.Exec.kill_pane }

(* State.read_all, not a per-pane view: the orphan rule needs every record. *)
let reap =
  Cmd.v (Cmd.info "reap" ~doc:"Close the finished subagent windows a sweep names.")
  @@ let+ args = rest in
     Cli.run "reap" (fun () ->
         if not (List.is_empty args) then failwith "usage: kido reap";
         let dir = State.dir () in
         Reap.collect ~dir ~capture:Reap.capture_pane ~grace:(Reap.grace ())
           (Tmux.Exec.list_panes ()) (State.read_all ~dir) ~now:(Unix.gettimeofday ()) release_ops;
         0)

(* Strict about the argument: kill-window resolves any target syntax, so any other spelling would
   pass the focus check (matching no pane) and kill a window the user may be reading. *)
let close_run =
  Cmd.v (Cmd.info "close-run" ~doc:"Collect a finished run's pane, or its whole window.")
  @@ let+ args = rest in
     Cli.run "close-run" (fun () ->
         let window_id =
           match args with
           | [ w ] when not (String.is_empty w) -> w
           | _ -> failwith "usage: kido close-run WINDOW_ID"
         in
         if
           not
             (String.prefix ~pre:"@" window_id
             && String.length window_id > 1
             && String.for_all Char.Ascii.is_digit (String.drop 1 window_id))
         then failwith (Printf.sprintf "close-run: %S is not a window id (@N)" window_id);
         (match Reap.decide (Tmux.Exec.list_panes ()) window_id with
         | Ok c -> Reap.release release_ops c
         | Error refusal -> Cli.error "close-run" refusal);
         0)

(* The fork sets TMUX_SIDE_CLIENT only for the side-status-command job, so its absence is exactly
   "not started as a side column". *)
let sidebar =
  let+ interval =
    Arg.(
      value & opt duration 0.1
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
  Ui.run ~interval ~client

let () =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let cmd =
    Cmd.group ~default:sidebar (Cmd.info "kido")
      [ hook; agent_status; debug_log; inbox_path; reap; close_run ]
  in
  exit
    (match Cmd.eval_value ~catch:false cmd with
    | Ok (`Ok code) -> code
    | Ok (`Help | `Version) -> 0
    (* Claude Code runs kido hook, which must never fail it. *)
    | Error _ when Array.length Sys.argv > 1 && String.equal Sys.argv.(1) "hook" -> 0
    | Error _ -> 1)
