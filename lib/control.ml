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

let kill_run_pane ?(before = ignore) pane_id =
  let open Result.Infix in
  let* panes = Exec.list_panes () in
  match Pane.find panes pane_id with
  | None -> Ok `Gone
  | Some p when Pane.last_window panes p.window_id && Pane.last_pane panes p.window_id ->
      Error "it is its session's only pane; killing it would destroy the session"
  | Some p ->
      before ();
      let+ () = Reap.release (Pane { window = p.window_id; pane = p.pane_id }) in
      `Killed

let record_stopped ~dir id =
  Result.iter
    (fun id ->
      ignore
        (Subrun.record_outcome ~dir id
           { result = Stopped; text = ""; at = Some (Timestamp.now ()) }))
    (Subrun.parse_id id)

let request ~states ~panes ~self kind target =
  Message_agent.deliver ~states ~panes ~self { kind; reply_to = ""; id = "" } target ""

let interrupt ~dir ~self to_ =
  let open Result.Infix in
  let live = State.load_live ~dir in
  let* panes = Exec.list_panes () in
  let* _, target = Message_agent.resolve ~live ~panes ~self (Descendant to_) in
  match request ~states:(State.by_pane live) ~panes ~self Interrupt target with
  | Ok _ -> Ok ("interrupted " ^ List_runs.display_name panes target)
  | Error (Message_agent.Unavailable m | Failed m) -> Error m

let stop ~dir ~self ~escalation ~warn ~force to_ =
  let open Result.Infix in
  let unforced what =
    if force then Ok () else Error (what ^ "; pass --force to kill its window instead")
  in
  let runs = List.filter_map (Subrun.read_meta ~dir) (Subrun.list ~dir) in
  let ids =
    List.filter
      (fun (m : Subrun.meta) ->
        let id = Subrun.string_of_id m.id in
        String.equal id to_ || (String.length to_ >= 8 && String.prefix ~pre:to_ id))
      runs
  in
  let matches =
    match
      List.find_opt (fun (m : Subrun.meta) -> String.equal (Subrun.string_of_id m.id) to_) ids
    with
    | Some m -> [ m ]
    | None when not (List.is_empty ids) -> ids
    | None ->
        List.filter
          (fun (m : Subrun.meta) ->
            String.equal_caseless m.name to_ && Option.is_none (Subrun.read_outcome ~dir m.id))
          runs
  in
  let* meta =
    match matches with
    | [ m ] -> Ok m
    | [] -> Error (Printf.sprintf "no run matches %S" to_)
    | many ->
        Error
          (Printf.sprintf "%S matches several runs: %s" to_
             (String.concat ", "
                (List.sort String.compare
                   (List.map (fun (m : Subrun.meta) -> Subrun.string_of_id m.id) many))))
  in
  let* () =
    if Option.is_none (Subrun.read_outcome ~dir meta.id) then Ok ()
    else Error (Printf.sprintf "run %s has already ended" (Subrun.string_of_id meta.id))
  in
  let live = State.load_live ~dir in
  let* panes = Exec.list_panes () in
  match meta.kind with
  | Bash -> (
      let* reached =
        Message_agent.reaches (List_runs.per_pane live) panes ~self meta.parent_session
      in
      let label = "async run " ^ Reap.quote (Subrun.label meta) in
      if not reached then Error (label ^ " is not this agent's descendant")
      else
        let ending =
          Reap.record_ending ~dir meta
            { result = Stopped; text = "stopped by its parent"; at = Some (Timestamp.now ()) }
        in
        let signalled =
          meta.pid > 0
          &&
          match Unix.kill meta.pid Sys.sigterm with
          | () -> true
          | exception Unix.Unix_error _ -> false
        in
        let gone = (not signalled) || wait_for escalation (fun () -> not (State.alive meta.pid)) in
        (if not gone then try Unix.kill meta.pid Sys.sigkill with Unix.Unix_error _ -> ());
        Option.iter
          (fun e -> Result.iter_err (fun e -> warn (Msg.string_of_error e)) (Reap.send ~dir e))
          ending;
        if gone && signalled then Ok (Printf.sprintf "stopped %s" label)
        else
          match kill_run_pane meta.pane with
          | Ok `Killed -> Ok (Printf.sprintf "stopped %s; killed its pane" label)
          | Ok `Gone -> Ok (Printf.sprintf "stopped %s; its pane was already gone" label)
          | Error m ->
              Error
                (Printf.sprintf "%s was recorded stopped, but its pane could not be killed: %s"
                   label m))
  | Agent -> (
      let* id, target = Message_agent.resolve ~live ~panes ~self (Descendant_run meta.id) in
      let name = "subagent " ^ List_runs.display_name panes target in
      let degrade () =
        match kill_run_pane ~before:(fun () -> record_stopped ~dir id) target.pane with
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
          match kill_run_pane target.pane with
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
