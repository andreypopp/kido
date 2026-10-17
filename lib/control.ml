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
  let tmux = Tmux.create () in
  let* panes = Tmux_pane.list_panes tmux in
  match Option.flat_map (Tmux_pane.find panes) pane_id with
  | None -> Ok `Gone
  | Some p when Tmux_pane.last_window panes p.window_id && Tmux_pane.last_pane panes p.window_id ->
      Error "it is its session's only pane; killing it would destroy the session"
  | Some p ->
      before ();
      let+ () = Reap.release tmux (Pane { window = p.window_id; pane = p.pane_id }) in
      `Killed

let record_stopped ~dir id =
  ignore (Run.record_outcome ~dir id { result = Stopped; text = ""; at = Some (Timestamp.now ()) })

let request ~dir ~caller ~panes ~self kind target =
  Message_agent.deliver ~dir ~caller ~panes ~self { kind; reply_to = ""; id = "" } target ""

let interrupt ~dir ~self ~caller to_ =
  let open Result.Infix in
  let* panes = Tmux_pane.list_panes (Tmux.create ()) in
  let* ((_, target) as e) = Message_agent.resolve ~dir ~panes ~self ~caller (Descendant to_) in
  match request ~dir ~caller ~panes ~self Interrupt e with
  | Ok _ -> Ok ("interrupted " ^ Run.display_name panes target)
  | Error (Message_agent.Unavailable m | Failed m) -> Error m

let stop ~dir ~self ~caller ~escalation ~warn ~force to_ =
  let open Result.Infix in
  let unforced what =
    if force then Ok () else Error (what ^ "; pass --force to kill its window instead")
  in
  let* panes = Tmux_pane.list_panes (Tmux.create ()) in
  let runs = List.filter_map (Run.read_meta ~dir) (Run.list ~dir) in
  let ids =
    List.filter
      (fun (m : Run.meta) ->
        let id = Run.string_of_id m.id in
        String.equal id to_ || (String.length to_ >= 8 && String.prefix ~pre:to_ id))
      runs
  in
  let matches =
    match List.find_opt (fun (m : Run.meta) -> String.equal (Run.string_of_id m.id) to_) ids with
    | Some m -> [ m ]
    | None when not (List.is_empty ids) -> ids
    | None ->
        List.filter
          (fun (m : Run.meta) ->
            let named =
              match Run.live_pi ~dir m.id with
              | Some s -> (not (String.is_empty s.name)) && String.equal_caseless s.name to_
              | None -> String.equal_caseless m.name to_
            in
            named && Option.is_none (Run.read_outcome ~dir m.id))
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
                   (List.map (fun (m : Run.meta) -> Run.string_of_id m.id) many))))
  in
  let* () =
    match meta.kind with
    | Pi -> Ok ()
    | Agent | Bash | Stream ->
        if Option.is_none (Run.read_outcome ~dir meta.id) then Ok ()
        else Error (Printf.sprintf "run %s has already ended" (Run.string_of_id meta.id))
  in
  match meta.kind with
  | Bash | Stream -> (
      let label = "async run " ^ Reap.quote (Run.label meta) in
      if not (Message_agent.reaches ~dir ~caller:(Option.map fst caller) meta.id) then
        Error (label ^ " is not this agent's descendant")
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
        let gone = (not signalled) || wait_for escalation (fun () -> not (Run.alive meta.pid)) in
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
  | Pi -> Error "a top-level pi run cannot be stopped with stop_run"
  | Agent -> (
      let* ((id, target) as e) =
        Message_agent.resolve ~dir ~panes ~self ~caller (Descendant_run meta.id)
      in
      let name = "subagent " ^ Run.display_name panes target in
      let degrade () =
        match kill_run_pane ~before:(fun () -> record_stopped ~dir id) target.pane with
        | Ok `Killed -> Ok (Printf.sprintf "killed %s's pane" name)
        | Ok `Gone -> Ok (Printf.sprintf "%s's pane was already gone" name)
        | Error m -> Error (Printf.sprintf "%s %s" name m)
      in
      let escalate refusal =
        record_stopped ~dir id;
        let gone () = Option.is_none (Run.live_pi ~dir id) in
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
        match request ~dir ~caller ~panes ~self Stop e with
        | Error (Message_agent.Unavailable m) ->
            let* () = unforced (Printf.sprintf "%s could not be asked to stop (%s)" name m) in
            degrade ()
        | Ok _ -> escalate None
        | Error (Message_agent.Failed m) -> escalate (Some m))
