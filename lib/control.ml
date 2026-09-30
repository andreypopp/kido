open Tmux

let stop_escalation () = Timestamp.ms_env Sys.getenv_opt "KIDO_STOP_ESCALATION_MS" 5.

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
  let open Result.Infix in
  let* panes = list_panes () in
  match Pane.find panes pane_id with
  | None -> Ok `Gone
  | Some p when Pane.last_window panes p.window_id && Pane.last_pane panes p.window_id ->
      Error "it is its session's only pane; killing it would destroy the session"
  | Some p ->
      before ();
      let+ () = Reap.release ops { window_id = p.window_id; pane_id = Some p.pane_id } in
      `Killed

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
  let open Result.Infix in
  let live = State.load_live ~dir in
  let* panes = Lazy.force panes in
  let* _, target = Message_agent.resolve ~live ~panes ~self (Descendant to_) in
  match request ~states:(State.by_pane live) ~panes ~self Interrupt target with
  | Ok _ -> Ok ("interrupted " ^ List_agents.display_name panes target)
  | Error (Message_agent.Unavailable m | Failed m) -> Error m

let run_label (meta : Subrun.meta) =
  Printf.sprintf "async run %S"
    (if String.is_empty meta.name then Subrun.string_of_id meta.id else meta.name)

let stopped_text = "stopped by kido stop_subagent; its wrapper did not report"

let live_bash_run ~dir ~self ~list_panes to_ =
  let open Result.Infix in
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
  | [] -> Ok None
  | [ meta ] ->
      let live = List_agents.per_pane (State.load_live ~dir) in
      let* panes = list_panes () in
      let* reached = Message_agent.reaches live panes ~self meta.parent_session in
      if reached then Ok (Some meta) else Error (run_label meta ^ " is not this agent's descendant")
  | many ->
      Error
        (Printf.sprintf "%S matches several running async runs: %s" to_
           (String.concat ", "
              (List.sort String.compare
                 (List.map (fun (m : Subrun.meta) -> Subrun.string_of_id m.id) many))))

let stop_bash_run ~dir ~list_panes ~ops ~escalation ~warn (meta : Subrun.meta) =
  let label = run_label meta in
  let runs = runs dir in
  let signalled =
    meta.pid > 0
    && match Unix.kill meta.pid Sys.sigterm with () -> true | exception Unix.Unix_error _ -> false
  in
  if
    signalled
    && wait_for escalation (fun () -> Option.is_some (Subrun.read_outcome ~dir:runs meta.id))
  then Ok (Printf.sprintf "stopped %s; its wrapper reported the ending" label)
  else begin
    Reap.record_ending ~dir meta
      { result = Stopped; text = stopped_text; at = Some (Timestamp.now ()) }
    |> Option.iter (fun e ->
        Result.iter_err (fun e -> warn (Msg.string_of_error e)) (Reap.send ~dir e));
    match kill_run_pane ~list_panes ~ops meta.pane with
    | Ok `Killed -> Ok (Printf.sprintf "stopped %s; killed its pane" label)
    | Ok `Gone -> Ok (Printf.sprintf "stopped %s; its pane was already gone" label)
    | Error m ->
        Error
          (Printf.sprintf "%s was recorded stopped, but its pane could not be killed: %s" label m)
  end

let stop ~dir ~self ~list_panes ~ops ~escalation ~warn ~force to_ =
  let open Result.Infix in
  let unforced what =
    if force then Ok () else Error (what ^ "; pass --force to kill its window instead")
  in
  let* bash = live_bash_run ~dir ~self ~list_panes to_ in
  match bash with
  | Some meta ->
      let* () = unforced (run_label meta ^ " has no inbox to ask nicely over") in
      stop_bash_run ~dir ~list_panes ~ops ~escalation ~warn meta
  | None -> (
      let live = State.load_live ~dir in
      let* panes = list_panes () in
      let* id, target = Message_agent.resolve ~live ~panes ~self (Descendant to_) in
      let name = List_agents.display_name panes target in
      let degrade () =
        match
          kill_run_pane ~list_panes ~ops ~before:(fun () -> record_stopped ~dir id) target.pane
        with
        | Ok `Killed -> Ok (Printf.sprintf "killed %s's pane" name)
        | Ok `Gone -> Ok (Printf.sprintf "%s's pane was already gone" name)
        | Error m -> Error (Printf.sprintf "%s %s" name m)
      in
      let escalate refusal =
        record_stopped ~dir id;
        let gone () =
          match State.get ~dir id with None -> true | Some s -> not (State.alive s.pid)
        in
        if wait_for escalation gone then Ok ("stopped " ^ name)
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
          | Ok _ -> Ok (Printf.sprintf "%s %s; killed its pane" name why)
          | Error m ->
              Error (Printf.sprintf "%s %s, and its pane could not be killed: %s" name why m)
      in
      if String.is_empty target.inbox then
        let* () = unforced (name ^ " has no inbox to ask nicely over") in
        degrade ()
      else
        match request ~states:(State.by_pane live) ~panes ~self Stop target with
        | Error (Message_agent.Unavailable m) ->
            let* () = unforced (Printf.sprintf "%s could not be asked to stop (%s)" name m) in
            degrade ()
        | Ok _ -> escalate None
        | Error (Message_agent.Failed m) -> escalate (Some m))
