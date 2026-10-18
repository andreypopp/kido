let interrupt ~dir ~self ~caller to_ =
  let open Result.Infix in
  let* state = State.read ~dir (Tmux.create ()) in
  let* ((_, target) as e) = Message_agent.resolve ~dir ~state ~self ~caller (Descendant to_) in
  match Message_agent.deliver ~dir ~caller ~state ~self Interrupt e "" with
  | Ok _ -> Ok ("interrupted " ^ Pane_kind.display_name state target)
  | Error (Message_agent.Unavailable m | Failed m) -> Error m

type stopped =
  | Run_stopped of { label : string; result : Run_stop.t }
  | Agent_stopped of { name : string }
  | Agent_killed of { name : string; why : string option; pane : Run_stop.pane_result }

let stop ~dir ~self ~caller ~escalation ~warn ~force to_ =
  let open Result.Infix in
  let unforced what =
    if force then Ok () else Error (what ^ "; pass --force to kill its window instead")
  in
  let* state = State.read ~dir (Tmux.create ()) in
  let* meta = Run.select ~dir to_ in
  let* () =
    match meta.kind with
    | Pi -> Ok ()
    | Agent | Bash | Stream ->
        if Option.is_none (Run.read_outcome ~dir meta.id) then Ok ()
        else Error (Printf.sprintf "run %s has already ended" (Run.string_of_id meta.id))
  in
  match meta.kind with
  | Bash | Stream -> (
      let label = "async run " ^ Run_ending.quote (Run.label meta) in
      if not (Message_agent.reaches ~dir ~caller:(Option.map fst caller) meta.id) then
        Error (label ^ " is not this agent's descendant")
      else
        match
          Run_stop.stop ~dir ~wait:0. ~escalation ~result:Stopped ~text:"stopped by its parent"
            meta.id
        with
        | Error (Run_stop.No_run m | Run_stop.Ended m | Run_stop.Pi m) -> Error m
        | Ok t ->
            Option.iter
              (fun e ->
                Result.iter_err (fun e -> warn (Msg.string_of_error e)) (Run_ending.send ~dir e))
              t.ending;
            Ok (Run_stopped { label; result = t }))
  | Pi -> Error "a top-level pi run cannot be stopped with stop_run"
  | Agent -> (
      let* ((id, target) as e) =
        Message_agent.resolve ~dir ~state ~self ~caller (Descendant_run meta.id)
      in
      let name = "subagent " ^ Pane_kind.display_name state target in
      let record_stop () =
        ignore
          (Run_ending.record_ending ~dir meta
             { result = Run_ending.stop_result ~dir meta; text = ""; at = Some (Timestamp.now ()) })
      in
      let degrade () =
        Ok
          (Agent_killed
             { name; why = None; pane = Run_stop.close_pane ~dir ~before:record_stop target.pane })
      in
      let escalate refusal =
        record_stop ();
        let gone () = Option.is_none (Run.live_pi ~dir id) in
        if Run_stop.wait_until ~within:escalation gone then Ok (Agent_stopped { name })
        else
          let after = Timestamp.duration escalation in
          let why =
            match refusal with
            | None -> "did not stop within " ^ after
            | Some m ->
                Printf.sprintf "did not accept the stop request (%s) and was still there after %s" m
                  after
          in
          Ok (Agent_killed { name; why = Some why; pane = Run_stop.close_pane ~dir target.pane })
      in
      if String.is_empty target.inbox then
        let* () = unforced (name ^ " has no inbox to ask nicely over") in
        degrade ()
      else
        match Message_agent.deliver ~dir ~caller ~state ~self Stop e "" with
        | Error (Message_agent.Unavailable m) ->
            let* () = unforced (Printf.sprintf "%s could not be asked to stop (%s)" name m) in
            degrade ()
        | Ok _ -> escalate None
        | Error (Message_agent.Failed m) -> escalate (Some m))
