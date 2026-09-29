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

let shell =
  Cmd.v (Cmd.info "shell" ~doc:"Exec the pane's login shell, primed with kido's shell integration.")
  @@ let+ () = Term.const () in
     Cli.run "shell" Shell.run

let ssh =
  Cmd.v (Cmd.info "ssh" ~doc:"Run ssh, priming the remote login shell when it can.")
  @@ let+ args = rest in
     Cli.run "ssh" (fun () -> Ssh.run args)

let default =
  let+ () = Term.const () in
  match (Sys.argv, Sys.getenv_opt "TMUX_SIDE_CLIENT") with
  | [| _ |], (None | Some "") ->
      Cli.run "" (fun () -> Launch.run ~tmux:(Option.get_or ~default:"" (Sys.getenv_opt "TMUX")))
  | _ -> failwith "sidebar: not merged yet"

let () =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let cmd =
    Cmd.group ~default (Cmd.info "kido") [ hook; agent_status; debug_log; inbox_path; shell; ssh ]
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
    (* Claude Code runs kido hook, which must never fail it. *)
    | Error _ when Array.length Sys.argv > 1 && String.equal Sys.argv.(1) "hook" -> 0
    | Error _ -> 1)
