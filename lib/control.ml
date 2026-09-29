open Tmux

let window_focused ~panes window =
  if String.is_empty window then failwith "usage: kido window-focused WINDOW_ID";
  if not (Pane.is_window_id window) then
    Cli.failf "window-focused: %S is not a window id (@N)" window;
  print_endline (Bool.to_string (Pane.window_focused (Lazy.force panes) window));
  0

let switch f ~client ~side_client ~next =
  f
    ~client:
      (List.find_opt (fun c -> not (String.is_empty c)) [ client; side_client ]
      |> Option.get_lazy Exec.current_client)
    ~next;
  0

let stop_escalation () = Cli.ms_env Sys.getenv_opt "KIDO_STOP_ESCALATION_MS" 5.

let wait_for within cond =
  let deadline = Unix.gettimeofday () +. within in
  let rec go () =
    cond ()
    || Float.(Unix.gettimeofday () < deadline)
       && begin
         Unix.sleepf 0.1;
         go ()
       end
  in
  go ()

let kill_run_pane ~list_panes ~ops ?(before = ignore) pane_id =
  let panes = list_panes () in
  match Pane.find panes pane_id with
  | None -> Ok `Gone
  | Some p when Pane.last_window panes p.window_id && Pane.last_pane panes p.window_id ->
      Error "it is its session's only pane; killing it would destroy the session"
  | Some p -> (
      before ();
      match Reap.release ops { window_id = p.window_id; pane_id = Some p.pane_id } with
      | () -> Ok `Killed
      | exception Failure m -> Error m)

let runs dir = Filename.concat dir "runs"

let record_stopped ~dir id =
  Result.iter
    (fun id ->
      ignore
        (Subrun.record_outcome ~dir:(runs dir) id
           { result = Stopped; text = ""; at = Some (Timestamp.now ()) }))
    (Subrun.parse_id id)

let request ~states ~panes ~self kind target =
  Message_agent.deliver ~states ~panes ~self ~paste:Exec.send_prompt
    { kind; reply_to = ""; id = "" } target ""

let interrupt ~dir ~self ~panes to_ =
  let live = State.load_live ~dir in
  let panes = Lazy.force panes in
  let _, target = Message_agent.resolve ~live ~panes ~self (Descendant to_) in
  match request ~states:(State.by_pane live) ~panes ~self Interrupt target with
  | Ok _ ->
      Printf.printf "interrupted %s\n" (List_agents.display_name panes target);
      0
  | Error (Message_agent.Unavailable m | Failed m) -> failwith m

let run_label (meta : Subrun.meta) =
  Printf.sprintf "async run %S"
    (if String.is_empty meta.name then Subrun.string_of_id meta.id else meta.name)

let stopped_text = "stopped by kido stop_subagent; its wrapper did not report"

let live_bash_run ~dir ~self ~list_panes to_ =
  let runs = runs dir in
  let matches =
    List.filter_map
      (fun id ->
        match Subrun.read_meta ~dir:runs id with
        | Some ({ kind = Some Bash; _ } as meta)
          when (String.equal_caseless meta.name to_ || String.equal (Subrun.string_of_id id) to_)
               && Option.is_none (Subrun.read_outcome ~dir:runs id) ->
            Some meta
        | _ -> None)
      (Subrun.list ~dir:runs)
  in
  match matches with
  | [] -> None
  | [ meta ] ->
      let live = List_agents.per_pane (State.load_live ~dir) in
      if Message_agent.reaches live (list_panes ()) ~self meta.parent_session then Some meta
      else Cli.failf "%s is not this agent's descendant" (run_label meta)
  | many ->
      Cli.failf "%S matches several running async runs: %s" to_
        (String.concat ", "
           (List.sort String.compare
              (List.map (fun (m : Subrun.meta) -> Subrun.string_of_id m.id) many)))

let stop_bash_run ~dir ~list_panes ~ops ~escalation (meta : Subrun.meta) =
  let label = run_label meta in
  let runs = runs dir in
  let signalled =
    meta.pid > 0
    && match Unix.kill meta.pid Sys.sigterm with () -> true | exception Unix.Unix_error _ -> false
  in
  if
    signalled
    && wait_for escalation (fun () -> Option.is_some (Subrun.read_outcome ~dir:runs meta.id))
  then Printf.printf "stopped %s; its wrapper reported the ending\n" label
  else begin
    Reap.record_ending ~dir meta
      { result = Stopped; text = stopped_text; at = Some (Timestamp.now ()) }
    |> Option.iter (fun e ->
        Result.iter_err
          (fun e -> Cli.error "stop_subagent" (Msg.string_of_error e))
          (Reap.send ~dir e));
    match kill_run_pane ~list_panes ~ops meta.pane with
    | Ok `Killed -> Printf.printf "stopped %s; killed its pane\n" label
    | Ok `Gone -> Printf.printf "stopped %s; its pane was already gone\n" label
    | Error m -> Cli.failf "%s was recorded stopped, but its pane could not be killed: %s" label m
  end

let stop ~dir ~self ~list_panes ~ops ~escalation ~force to_ =
  let refuse_unforced what =
    if not force then Cli.failf "%s; pass --force to kill its window instead" what
  in
  (match live_bash_run ~dir ~self ~list_panes to_ with
  | Some meta ->
      refuse_unforced (run_label meta ^ " has no inbox to ask nicely over");
      stop_bash_run ~dir ~list_panes ~ops ~escalation meta
  | None -> (
      let live = State.load_live ~dir in
      let panes = list_panes () in
      let id, target = Message_agent.resolve ~live ~panes ~self (Descendant to_) in
      let name = List_agents.display_name panes target in
      let degrade () =
        match
          kill_run_pane ~list_panes ~ops ~before:(fun () -> record_stopped ~dir id) target.pane
        with
        | Ok `Killed -> Printf.printf "killed %s's pane\n" name
        | Ok `Gone -> Printf.printf "%s's pane was already gone\n" name
        | Error m -> Cli.failf "%s %s" name m
      in
      let escalate refusal =
        record_stopped ~dir id;
        let gone () =
          match State.get ~dir id with None -> true | Some s -> not (State.alive s.pid)
        in
        if wait_for escalation gone then Printf.printf "stopped %s\n" name
        else
          let after = Timestamp.duration escalation in
          let why =
            match refusal with
            | None -> "did not stop within " ^ after
            | Some m ->
                Printf.sprintf "did not accept the stop request (%s) and was still there after %s" m
                  after
          in
          match kill_run_pane ~list_panes ~ops target.pane with
          | Ok _ -> Printf.printf "%s %s; killed its pane\n" name why
          | Error m -> Cli.failf "%s %s, and its pane could not be killed: %s" name why m
      in
      if String.is_empty target.inbox then begin
        refuse_unforced (name ^ " has no inbox to ask nicely over");
        degrade ()
      end
      else
        match request ~states:(State.by_pane live) ~panes ~self Stop target with
        | Error (Message_agent.Unavailable m) ->
            refuse_unforced (Printf.sprintf "%s could not be asked to stop (%s)" name m);
            degrade ()
        | Ok _ -> escalate None
        | Error (Message_agent.Failed m) -> escalate (Some m)));
  0
