open Cmdliner
open Cmdliner.Term.Syntax
open Kido

let rest = Arg.(value & pos_all string [] & info [] ~docv:"ARG")
let str name docv doc = Arg.(value & opt string "" & info [ name ] ~docv ~doc)
let num name docv doc = Arg.(value & opt int 0 & info [ name ] ~docv ~doc)
let flag name doc = Arg.(value & flag & info [ name ] ~doc)
let arg docv = Arg.(required & pos 0 (some string) None & info [] ~docv)
let env name = Option.get_or ~default:"" (Sys.getenv_opt name)
let stdin () = In_channel.input_all stdin
let panes = lazy (Tmux.Exec.list_panes ())
let cmd name doc term = Cmd.v (Cmd.info name ~doc) Term.(const (fun f -> Cli.run name f) $ term)

let send name doc spec =
  cmd name doc
  @@ let+ spec = spec in
     fun () ->
       Message_agent.send ~dir:(State.dir ()) ~self:(env "TMUX_PANE") ~panes
         ~paste:Tmux.Exec.send_prompt spec (stdin ())

let message_agent =
  send "message_agent" "Send a message to another agent, read from stdin."
  @@ let+ reply_to = str "reply-to" "ID" "Id of an earlier ask this message answers."
     and+ to_ = arg "TO" in
     Message_agent.
       {
         kind = (if String.is_empty reply_to then Message else Reply);
         recipient = Named to_;
         reply_to;
         id = "";
       }

let ask_agent =
  send "ask_agent" "Ask another agent a question, read from stdin; its answer comes as a reply."
  @@ let+ id = str "id" "ID" "Id to assign this envelope; a fresh one is generated if omitted."
     and+ to_ = arg "TO" in
     Message_agent.{ kind = Ask; recipient = Named to_; reply_to = ""; id }

let notify_parent =
  cmd "notify_parent" "Send this subagent's report, read from stdin, to its parent."
  @@ let+ () = Term.const () in
     fun () ->
       Message_agent.notify_parent ~dir:(State.dir ()) ~self:(env "TMUX_PANE") ~panes
         ~paste:Tmux.Exec.send_prompt ~parent:(env "KIDO_AGENT_PARENT_SESSION")
         ~run:(env "KIDO_AGENT_RUN_ID") (stdin ())

let list_agents =
  cmd "list_agents" "List the agents in a tmux session."
  @@ let+ session =
       str "session" "ID" "tmux session id to list; defaults to the caller's own session."
     and+ json = flag "json" "Print JSON instead of a table." in
     fun () ->
       List_agents.list_agents ~dir:(State.dir ()) ~threshold:(State.stall_threshold ())
         ~self:(env "TMUX_PANE") ~panes ~session ~json

let set_status =
  cmd "set_status" "Set this agent's activity; an empty one clears it."
  @@ let+ activity = arg "ACTIVITY" in
     fun () -> Set_status.set_status ~dir:(State.dir ()) ~self:(env "TMUX_PANE") activity

let agent_alive =
  cmd "agent-alive" "Print whether a live process holds an agent session."
  @@ let+ session = arg "SESSION" in
     fun () -> Agent_alive.agent_alive ~dir:(State.dir ()) session

let children_alive =
  cmd "children-alive" "Print whether any subagent spawned by a session is still running."
  @@ let+ session = arg "SESSION" in
     fun () -> Agent_alive.children_alive ~dir:(State.dir ()) session

let snapshot =
  cmd "snapshot" "Print a shell script that recreates the current tmux sessions."
  @@ let+ () = Term.const () in
     fun () -> Snapshot.snapshot ~dir:(State.dir ())

let prompt =
  cmd "prompt" "Send a prompt, read from stdin, to the agent in the caller's window or session."
  @@ let+ window =
       flag "window" "Search only the caller's window, never widening to the session."
     in
     fun () -> Prompt.prompt ~dir:(State.dir ()) ~self:(env "TMUX_PANE") ~window (stdin ())

let window_focused =
  cmd "window-focused" "Print whether a client is looking at a window."
  @@ let+ window = arg "WINDOW_ID" in
     fun () -> Control.window_focused ~panes window

let switch name doc f =
  cmd name doc
  @@ let+ next =
       Arg.(
         required
         & pos 0 (some (enum [ ("next", true); ("prev", false) ])) None
         & info [] ~docv:"next|prev")
     and+ client = str "client" "NAME" "tmux client to switch; defaults to $TMUX_SIDE_CLIENT." in
     fun () -> Control.switch f ~client ~side_client:(env "TMUX_SIDE_CLIENT") ~next

let switch_session =
  switch "switch-session" "Switch the client to the next or previous session."
    Tmux.Exec.switch_session

let switch_window =
  switch "switch-window" "Switch the client to the next or previous window." Tmux.Exec.switch_window

let created name f =
  Cli.run name (fun () ->
      print_endline (f ());
      0)

let spawn_subagent =
  Cmd.v (Cmd.info "spawn_subagent" ~doc:"Spawn a subagent in its own tmux window, or resume one.")
  @@ let+ parent_pid = num "parent-pid" "PID" "Pid of the agent spawning this one."
     and+ parent_session = str "parent-session" "ID" "Session id of the agent spawning this one."
     and+ name = str "name" "NAME" "Window name, and (by convention) the child's own --name."
     and+ task_file =
       str "task-file" "FILE"
         "File holding the task text to deliver as the child's first message, or - for stdin."
     and+ model =
       str "model" "M" "Model the child will run, recorded in the run's meta for kido runs."
     and+ tools =
       str "tools" "T,..."
         "Comma-separated tool allowlist the child will run, recorded in the run's meta for kido \
          runs."
     and+ resume =
       str "resume" "RUN_ID" "Resume an existing run's own session instead of starting a new one."
     and+ fork =
       str "fork" "SESSION_ID"
         "Seed the child's session with this pi session's transcript, so it starts holding the \
          caller's context."
     and+ keep_alive =
       flag "keep-alive" "The child does not self-reap after going idle (KIDO_AGENT_KEEP_ALIVE)."
     and+ no_parent =
       flag "no-parent"
         "Spawn with no parent edge at all: the child reports to nobody, arms no idle timer, and \
          is never reaped as an orphan."
     and+ command = rest in
     created "spawn_subagent" (fun () ->
         Spawn_subagent.spawn ~dir:(State.dir ()) ~self:(env "TMUX_PANE") ~panes
           ~tmux:Spawn_subagent.tmux
           ~pi:
             {
               list_models = Spawn_subagent.list_models ~path:(env "PATH");
               session_dir = env "PI_CODING_AGENT_SESSION_DIR";
               agent_dir = env "PI_CODING_AGENT_DIR";
               home = env "HOME";
             }
           (Spawn_subagent.parse
              {
                parent_pid;
                parent_session;
                name;
                task_file;
                model;
                tools;
                resume;
                fork;
                keep_alive;
                no_parent;
                command;
              }))

let async_bash =
  Cmd.v (Cmd.info "async_bash" ~doc:"Run a command in the background, in its own tmux window.")
  @@ let+ name = str "name" "NAME" "Window name; derived from the command when omitted."
     and+ stream = flag "stream" "Send the command's output to this caller in batches as it runs."
     and+ args = rest in
     created "async_bash" (fun () ->
         Async_bash.async_bash ~dir:(State.dir ()) ~self:(env "TMUX_PANE")
           ~exe:(Tmux.Exec.invoked_path ~path:(env "PATH") Sys.argv.(0))
           ~panes ~tmux:Spawn_subagent.tmux ~name ~stream args)

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
    Cmd.group ~default (Cmd.info "kido")
      [
        hook;
        agent_status;
        debug_log;
        inbox_path;
        message_agent;
        ask_agent;
        notify_parent;
        list_agents;
        set_status;
        agent_alive;
        children_alive;
        snapshot;
        prompt;
        window_focused;
        switch_session;
        switch_window;
        shell;
        ssh;
        spawn_subagent;
        async_bash;
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
    (* Claude Code runs kido hook, which must never fail it. *)
    | Error _ when Array.length Sys.argv > 1 && String.equal Sys.argv.(1) "hook" -> 0
    | Error _ -> 1)
