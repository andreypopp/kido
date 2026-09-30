open Cmdliner
open Cmdliner.Term.Syntax
open Kido

let rest = Arg.(value & pos_all string [] & info [] ~docv:"ARG")
let str name docv doc = Arg.(value & opt string "" & info [ name ] ~docv ~doc)
let num name docv doc = Arg.(value & opt int 0 & info [ name ] ~docv ~doc)
let flag name doc = Arg.(value & flag & info [ name ] ~doc)
let arg docv = Arg.(required & pos 0 (some string) None & info [] ~docv)

let stdin () =
  let s = In_channel.input_all stdin in
  Option.get_or ~default:s (String.chop_suffix ~suf:"\n" s)

let panes = lazy (Tmux.Exec.list_panes ())
let cmd name doc term = Cmd.v (Cmd.info name ~doc) Term.(const (fun f -> Cli.run name f) $ term)
let ok = Result.get_or_failwith

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
  cmd name doc
  @@ let+ recipient, spec = spec in
     fun () ->
       sent
         (Message_agent.send ~dir:(State.dir ()) ~self:(Tmux.Exec.getenv "TMUX_PANE") recipient spec
            (stdin ()))

let message_agent =
  send "message_agent" "Send a message to another agent, read from stdin."
  @@ let+ reply_to = str "reply-to" "ID" "Id of an earlier ask this message answers."
     and+ to_ = arg "TO" in
     ( Message_agent.Named to_,
       Message_agent.
         { kind = (if String.is_empty reply_to then Message else Reply); reply_to; id = "" } )

let ask_agent =
  send "ask_agent" "Ask another agent a question, read from stdin; its answer comes as a reply."
  @@ let+ id = str "id" "ID" "Id to assign this envelope; a fresh one is generated if omitted."
     and+ to_ = arg "TO" in
     (Message_agent.Named to_, Message_agent.{ kind = Ask; reply_to = ""; id })

let steer_subagent =
  send "steer_subagent" "Steer a descendant agent mid-turn with a message read from stdin."
  @@ let+ to_ = arg "AGENT" in
     (Message_agent.Descendant to_, Message_agent.{ kind = Steer; reply_to = ""; id = "" })

let interrupt_subagent =
  cmd "interrupt_subagent" "Abort a descendant agent's current turn."
  @@ let+ to_ = arg "AGENT" in
     fun () ->
       print (Control.interrupt ~dir:(State.dir ()) ~self:(Tmux.Exec.getenv "TMUX_PANE") to_)

let stop_subagent =
  cmd "stop_subagent" "Stop a descendant agent, or an async run."
  @@ let+ force =
       flag "force" "Kill the target's window directly when it has no inbox to ask nicely over."
     and+ to_ = arg "AGENT" in
     fun () ->
       print
         (Control.stop ~dir:(State.dir ()) ~self:(Tmux.Exec.getenv "TMUX_PANE")
            ~escalation:(Control.stop_escalation ()) ~warn:(Cli.error "stop_subagent") ~force to_)

let runs =
  cmd "runs" "List subagent and async runs, or show one."
  @@ let+ json = flag "json" "Print JSON instead of a table." and+ args = rest in
     fun () ->
       let dir = State.dir () in
       match args with
       | [] ->
           let infos = Runs.list ~dir in
           if json then
             print_endline (Yojson.Safe.to_string (`List (List.map Runs.info_to_yojson infos)))
           else Cli.table (Runs.table ~now:(Timestamp.now ()) infos);
           0
       | [ id ] ->
           print_string (ok (Runs.show ~dir ~json id));
           0
       | _ :: extra :: _ ->
           Printf.ksprintf failwith "unknown argument %S\nusage: kido runs [--json] [<run-id>]"
             extra

let run_outcome =
  cmd "run-outcome" "Record a run's own outcome."
  @@ let+ result =
       Arg.(
         required
         & opt (some (enum [ ("completed", Subrun.Completed); ("failed", Failed) ])) None
         & info [ "result" ] ~docv:"RESULT" ~doc:"completed or failed.")
     and+ text = str "text" "TEXT" "Optional detail."
     and+ unreported = flag "unreported" "The child never called notify_parent: tell its parent so."
     and+ id = arg "RUN_ID" in
     fun () ->
       ok
         (Runs.run_outcome ~dir:(State.dir ()) ~warn:(Cli.error "run-outcome") ~result ~text
            ~unreported id);
       0

let async_run =
  cmd "async-run" "Run an async run's command, recording and reporting how it ended."
  @@ let+ run_id =
       str "run-id" "ID" "The run this window is running; defaults to $(b,KIDO_AGENT_RUN_ID)."
     and+ stream = flag "stream" "Send the command's output to the parent in batches as it runs." in
     fun () ->
       ok
         (Async_run.async_run ~dir:(State.dir ())
            ~knobs:(Async_stream.knobs Sys.getenv_opt)
            ~warn:(Cli.error "async-run")
            ~run_id:
              (if String.is_empty run_id then Tmux.Exec.getenv "KIDO_AGENT_RUN_ID" else run_id)
            ~stream)

let notify_parent =
  cmd "notify_parent" "Send this subagent's report, read from stdin, to its parent."
  @@ let+ () = Term.const () in
     fun () ->
       sent
         (Message_agent.notify_parent ~dir:(State.dir ()) ~self:(Tmux.Exec.getenv "TMUX_PANE")
            ~warn:(Cli.error "notify_parent")
            ~parent:(Tmux.Exec.getenv "KIDO_AGENT_PARENT_SESSION")
            ~run:(Tmux.Exec.getenv "KIDO_AGENT_RUN_ID")
            (stdin ()))

let list_agents =
  cmd "list_agents" "List the agents in a tmux session."
  @@ let+ session =
       str "session" "ID" "tmux session id to list; defaults to the caller's own session."
     and+ json = flag "json" "Print JSON instead of a table." in
     fun () ->
       let agents =
         ok
           (List_agents.list_agents ~dir:(State.dir ()) ~threshold:(State.stall_threshold ())
              ~self:(Tmux.Exec.getenv "TMUX_PANE") ~session)
       in
       if json then
         print_endline
           (Yojson.Safe.to_string (`List (List.map List_agents.agent_info_to_yojson agents)))
       else Cli.table (List_agents.table agents);
       0

let set_status =
  cmd "set_status" "Set this agent's activity; an empty one clears it."
  @@ let+ activity = arg "ACTIVITY" in
     fun () ->
       let dir = State.dir () and self = Tmux.Exec.getenv "TMUX_PANE" in
       match State.String_map.find_opt self (State.by_pane (State.load_live ~dir)) with
       | None ->
           Printf.ksprintf failwith
             "no agent session has reported pane %S; there is nothing to set an activity on" self
       | Some (id, s) -> (
           match
             State.record ~dir id { s with activity = Reporting.one_line activity ~max:256 }
           with
           | Ok () -> 0
           | Error holder -> failwith (State.held_message id holder))

let answer name doc f =
  cmd name doc
  @@ let+ session = arg "SESSION" in
     fun () ->
       if String.is_empty session then Printf.ksprintf failwith "usage: kido %s SESSION" name;
       print_endline (Bool.to_string (f ~dir:(State.dir ()) session));
       0

let agent_alive =
  answer "agent-alive" "Print whether a live process holds an agent session." (fun ~dir session ->
      List.mem_assoc ~eq:String.equal session (State.load_live ~dir))

let children_alive =
  answer "children-alive" "Print whether any subagent spawned by a session is still running."
    (fun ~dir session ->
      List.exists
        (fun id ->
          match Subrun.read_meta ~dir id with
          | Some m ->
              String.equal m.parent_session session
              && Option.is_none (Subrun.effective_outcome ~dir id ~pid:m.pid)
          | None -> false)
        (Subrun.list ~dir))

type window = { session : string; index : int; layout : string; n : int }

let snapshot =
  cmd "snapshot" "Print a shell script that recreates the current tmux sessions."
  @@ let+ () = Term.const () in
     fun () ->
       let states = State.by_pane (State.load_live ~dir:(State.dir ())) in
       let pi = (Procs.sweep ()).pi in
       let q = Filename.quote in
       let tm = Unix.localtime (Unix.time ()) in
       Printf.printf
         "#!/bin/sh\n# tmux sessions captured by kido snapshot on %04d-%02d-%02d %02d:%02d.\n"
         (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday tm.tm_hour tm.tm_min;
       print_endline
         "# Run outside tmux, then attach. Claude Code and pi panes resume their session.";
       print_endline "set -e\nT=${TMUX_BIN:-tmux}";
       let close = function
         | Some w when not (String.is_empty w.layout) ->
             Printf.printf "$T select-layout -t \"$p0\" %s\n" (q w.layout)
         | _ -> ()
       in
       let step prev (p : Tmux.Pane.t) =
         let w =
           match prev with
           | Some w when String.equal w.session p.session_name && w.index = p.window_index ->
               let n = w.n + 1 in
               Printf.printf "p%d=$($T split-window -d -P -F '#{pane_id}' -t \"$p%d\" -c %s)\n" n
                 w.n (q p.current_path);
               { w with n }
           | _ ->
               close prev;
               let name = if String.is_empty p.window_name then "" else " -n " ^ q p.window_name in
               (match prev with
               | Some w when String.equal w.session p.session_name ->
                   Printf.printf "p0=$($T new-window -d -P -F '#{pane_id}' -t %s%s -c %s)\n"
                     (q p.session_name) name (q p.current_path)
               | _ ->
                   Printf.printf "\n# --- %s\n" p.session_name;
                   Printf.printf "p0=$($T new-session -d -P -F '#{pane_id}' -s %s%s -c %s)\n"
                     (q p.session_name) name (q p.current_path));
               { session = p.session_name; index = p.window_index; layout = p.window_layout; n = 0 }
         in
         let cmd =
           match State.String_map.find_opt p.pane_id states with
           | Some (id, ({ agent = Pi; _ } : State.session)) ->
               if String.is_empty id then "pi" else "pi --session " ^ id
           | Some (id, { agent = Claude; _ }) ->
               if String.is_empty id then "claude --continue" else "claude --resume " ^ id
           | _ when String.equal p.current_command "claude" -> "claude --continue"
           | _ when Procs.Int_set.mem p.pane_pid pi -> "pi"
           | _ -> ""
         in
         if not (String.is_empty cmd) then
           Printf.printf "$T send-keys -t \"$p%d\" %s Enter\n" w.n (q cmd);
         if p.active then
           Printf.printf "$T select-window -t \"$p%d\"; $T select-pane -t \"$p%d\"\n" w.n w.n;
         Some w
       in
       close (List.fold_left step None (ok (Tmux.Exec.list_panes ())));
       print_endline {|echo "recreated: $($T list-sessions -F '#{session_name}' | tr '\n' ' ')"|};
       0

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
       match
         Prompt.prompt ~dir:(State.dir ()) ~self:(Tmux.Exec.getenv "TMUX_PANE") ~window (stdin ())
       with
       | Ok () -> 0
       | Error No_prompt -> refuse "no prompt given" 1
       | Error Not_found -> refuse "agent not found" 4
       | Error Several -> refuse "multiple agents found" 5
       | Error (Failed m) -> failwith m

let window_focused =
  cmd "window-focused" "Print whether a client is looking at a window."
  @@ let+ window = arg "WINDOW_ID" in
     fun () ->
       if String.is_empty window then failwith "usage: kido window-focused WINDOW_ID";
       if not (Tmux.Pane.is_window_id window) then
         Printf.ksprintf failwith "%S is not a window id (@N)" window;
       print_endline (Bool.to_string (Tmux.Pane.window_focused (ok (Lazy.force panes)) window));
       0

let switch name doc f =
  cmd name doc
  @@ let+ next =
       Arg.(
         required
         & pos 0 (some (enum [ ("next", true); ("prev", false) ])) None
         & info [] ~docv:"next|prev")
     and+ client = str "client" "NAME" "tmux client to switch; defaults to $(b,TMUX_SIDE_CLIENT)."
     and+ socket =
       Arg.(
         value
         & opt (some string) None
         & info [ "socket" ] ~docv:"PATH"
             ~doc:"The tmux server's socket, for a caller outside tmux.")
     in
     fun () ->
       ok
         (f ~socket
            ~client:
              (List.find_opt
                 (fun c -> not (String.is_empty c))
                 [ client; Tmux.Exec.getenv "TMUX_SIDE_CLIENT" ]
              |> Option.get_lazy Tmux.Exec.current_client)
            ~next);
       0

let switch_session =
  switch "switch-session" "Switch the client to the next or previous session."
    Tmux.Exec.switch_session

let switch_window =
  switch "switch-window" "Switch the client to the next or previous window."
    (fun ~socket ~client ~next -> Sidebar.switch_window ~socket ~dir:(State.dir ()) ~client ~next)

let created name f = Cli.run name (fun () -> print (f ()))

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
         Result.flat_map
           (Spawn_subagent.spawn ~dir:(State.dir ()) ~self:(Tmux.Exec.getenv "TMUX_PANE")
              ~pi:
                {
                  path = Tmux.Exec.getenv "PATH";
                  session_dir = Tmux.Exec.getenv "PI_CODING_AGENT_SESSION_DIR";
                  agent_dir = Tmux.Exec.getenv "PI_CODING_AGENT_DIR";
                  home = Tmux.Exec.getenv "HOME";
                })
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
         Async_bash.async_bash ~dir:(State.dir ()) ~self:(Tmux.Exec.getenv "TMUX_PANE")
           ~exe:(Lazy.force Tmux.Exec.self) ~name ~stream args)

let hook =
  Cmd.v (Cmd.info "hook" ~doc:"Record a Claude Code hook event read from stdin.")
  @@ let+ args = rest in
     Cli.run ~failure:0 "hook" (fun () ->
         match args with
         | _ :: _ ->
             prerr_endline "usage: kido hook";
             0
         | [] ->
             ok
               (Reporting.hook ~dir:(State.dir ()) ~pane:(Tmux.Exec.getenv "TMUX_PANE")
                  ~debug:(not (String.is_empty (Tmux.Exec.getenv "KIDO_HOOK_DEBUG")))
                  (stdin ()));
             0)

let agent_status =
  Cmd.v (Cmd.info "agent-status" ~doc:"Report the status of an agent session.")
  @@ let+ agent =
       Arg.(
         required
         & opt (some string) None
         & info [ "agent" ] ~docv:"NAME" ~doc:"Name of the reporting agent, e.g. pi.")
     and+ session =
       Arg.(
         required
         & opt (some string) None
         & info [ "session" ] ~docv:"ID" ~doc:"The agent's session id; one state file per session.")
     and+ status =
       Arg.(
         value
         & opt (some (enum State.statuses)) None
         & info [ "status" ] ~docv:"STATUS"
             ~doc:"One of running, waiting, compacting or idle; required unless $(b,--remove).")
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
     and+ remove = flag "remove" "Delete the session's record." in
     Cli.run "agent-status" (fun () ->
         let dir = State.dir () in
         match
           match (remove, status) with
           | true, _ -> State.remove ~dir session ~pid:(Unix.getppid ())
           | false, None -> failwith "--status is required"
           | false, Some status ->
               Reporting.agent_status ~dir ~pane:(Tmux.Exec.getenv "TMUX_PANE") ~agent ~session
                 ~title ~inbox ~activity ~parent_pid ~parent_session ~depth ~model ~ended status
         with
         | Ok () -> 0
         | Error holder ->
             Cli.error "agent-status" (State.held_message session holder);
             6)

let debug_log =
  Cmd.v (Cmd.info "debug-log" ~doc:"Print the path of the hook debug log.")
  @@ let+ () = Term.const () in
     print_endline (Reporting.debug_log ~dir:(State.dir ()));
     0

let server =
  cmd "server" "Start the kido server detached unless it is running, and print its tmux and socket."
  @@ let+ () = Term.const () in
     fun () ->
       print_endline (Yojson.Safe.to_string (Launch.endpoint_to_yojson (ok (Launch.ensure ()))));
       0

let inbox_path =
  Cmd.v (Cmd.info "inbox-path" ~doc:"Print, and create the directory of, an agent's inbox socket.")
  @@ let+ args = rest in
     match args with
     | [ name ] -> Cli.run "inbox-path" (fun () -> print (Msg.inbox_path ~dir:(State.dir ()) name))
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
     Cli.run "ssh" (fun () ->
         let path = Tmux.Exec.getenv "PATH" in
         let ssh =
           match Bin_dir.own () with
           | Some dir ->
               Bin_dir.look_path_past ~path ~dir "ssh"
               |> Option.get_lazy (fun () -> failwith ("no ssh on PATH past " ^ dir))
           | None ->
               Tmux.Exec.look_path ~path "ssh"
               |> Option.get_lazy (fun () ->
                   failwith {|exec: "ssh": executable file not found in $PATH|})
         in
         let tty =
           match Unix.fstat Unix.stdin with
           | st -> Stdlib.(st.st_kind = S_CHR)
           | exception Unix.Unix_error _ -> false
         in
         let argv =
           match Procs.parse_ssh args with
           | Some a
             when tty && List.is_empty a.command
                  && not (String.exists (String.contains "NTWfsnOQVG") a.letters) ->
               ("ssh" :: a.opts) @ [ "-t"; a.dest; Prime.ssh_bootstrap ]
           | _ -> "ssh" :: args
         in
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

(* State.load_live, not a per-pane view: the orphan rule needs every record. *)
let reap =
  Cmd.v (Cmd.info "reap" ~doc:"Close the finished subagent windows a sweep names.")
  @@ let+ args = rest in
     Cli.run "reap" (fun () ->
         if not (List.is_empty args) then failwith "usage: kido reap";
         let dir = State.dir () in
         Reap.collect ~dir ~grace:(Reap.grace ())
           (ok (Tmux.Exec.list_panes ()))
           (State.load_live ~dir) ~now:(Unix.gettimeofday ());
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
         if not (Tmux.Pane.is_window_id window_id) then
           Printf.ksprintf failwith "%S is not a window id (@N)" window_id;
         (match Reap.decide (ok (Tmux.Exec.list_panes ())) window_id with
         | Ok c -> ok (Reap.release c)
         | Error refusal -> Cli.error "close-run" refusal);
         0)

(* The fork sets TMUX_SIDE_CLIENT only for the side-status-command job, so its absence is exactly
   "not started as a side column". *)
let sidebar =
  let+ interval =
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
  let side = Tmux.Exec.getenv "TMUX_SIDE_CLIENT" in
  match (Sys.argv, side, Sys.getenv_opt "TMUX") with
  | [| _ |], "", _ ->
      Cli.run "" (fun () ->
          match Launch.run ~tmux:(Tmux.Exec.getenv "TMUX") with Ok _ -> 0 | Error m -> failwith m)
  | _, _, None ->
      Cli.error "" "must run inside tmux";
      1
  | _, _, Some tmux_env -> (
      let client =
        match client with
        | Some c when not (String.is_empty c) -> Some c
        | _ when not (String.is_empty side) -> Some side
        | _ -> Tmux.Exec.resolve_client ~pane:(Tmux.Exec.getenv "TMUX_PANE") ~tmux_env
      in
      match client with
      | None ->
          Cli.error "" "no tmux client; pass --client '#{client_name}'";
          1
      | Some client ->
          Ui.run ~standalone:(String.is_empty side)
            {
              interval;
              client;
              socket = None;
              dir = State.dir ();
              threshold = State.stall_threshold ();
              grace = Reap.grace ();
            };
          0)

type input = Line of string | Eof | Read_error of string

let sidebar_feed =
  cmd "sidebar-feed" "Stream the sidebar's rows to a native sidebar, as one JSON line per change."
  @@ let+ socket = str "socket" "PATH" "The kido server's tmux socket."
     and+ client = str "client" "NAME" "The tmux client the rows are drawn for." in
     fun () ->
       if String.is_empty socket || String.is_empty client then
         failwith "usage: kido sidebar-feed --socket PATH --client NAME";
       if not (Sys.file_exists socket) then Printf.ksprintf failwith "no tmux server at %s" socket;
       let opts =
         {
           Sidebar.interval = Sidebar.default_interval;
           client;
           socket = Some socket;
           dir = State.dir ();
           threshold = State.stall_threshold ();
           grace = Reap.grace ();
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
       let conn = Tmux.Conn.connect ~socket client in
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
         let search =
           List.fold_left
             (fun search -> function
               | Line l -> ( match Sidebar.command l with Filter f -> f | Ignored -> search)
               | Eof | Read_error _ -> search)
             m.search inputs
         in
         let m, changed =
           if Option.equal String.equal search m.search then (m, changed)
           else (Sidebar.rebuild { m with search }, true)
         in
         let last =
           if not changed then last
           else
             match Sidebar.to_json m with
             | Some json ->
                 let line = Yojson.Safe.to_string json in
                 if not (String.equal line last) then (
                   print_endline line;
                   flush stdout);
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
         ~finally:(fun () -> Tmux.Conn.close conn)
         (fun () -> loop (Sidebar.make ~now:Unix.gettimeofday opts) "")

let () =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let cmd =
    Cmd.group ~default:sidebar (Cmd.info "kido")
      [
        hook;
        agent_status;
        debug_log;
        server;
        inbox_path;
        message_agent;
        ask_agent;
        notify_parent;
        steer_subagent;
        interrupt_subagent;
        stop_subagent;
        runs;
        run_outcome;
        async_run;
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
        reap;
        close_run;
        sidebar_feed;
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
