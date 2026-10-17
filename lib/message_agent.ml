type recipient =
  | Named of string
  | Descendant of string
  | Descendant_run of Run.id
  | Parent of Run.id

type address = Name of string | Run of Run.id
type spec = Message | Reply of string | Ask of string option | Notice | Steer | Interrupt | Stop
type failure = Unavailable of string | Failed of string
type send_error = No_text | Not_sent of string

let decide ~state to_ by = function
  | [] -> None
  | [ e ] -> Some (Ok e)
  | many ->
      List.map
        (fun (id, s) ->
          Printf.sprintf "%s (%s)" (Run.string_of_id id) (State.run_display_name state s))
        many
      |> List.sort String.compare |> String.concat ", "
      |> Printf.sprintf "%S matches several agents by %s: %s" to_ by
      |> fun m -> Some (Error m)

let match_target ~state sessions to_ =
  let named (_, (s : Run.pi)) =
    (not (String.is_empty s.name)) && String.equal_caseless s.name to_
  in
  match decide ~state to_ "name" (List.filter named sessions) with
  | Some r -> Some r
  | None -> (
      match List.find_opt (fun (id, _) -> String.equal (Run.string_of_id id) to_) sessions with
      | Some e -> Some (Ok e)
      | None ->
          decide ~state to_ "id"
            (List.filter (fun (id, _) -> String.prefix ~pre:to_ (Run.string_of_id id)) sessions))

let resolve_target states state ~self address =
  let open Result.Infix in
  let to_, matched =
    match address with
    | Name to_ -> (to_, fun states -> match_target ~state states to_)
    | Run id ->
        ( Run.string_of_id id,
          fun states -> Option.map (fun s -> Ok (id, s)) (List.assoc_opt ~eq:Run.equal_id id states)
        )
  in
  let* caller = State.caller_pane state self in
  let in_session (_, (s : Run.pi)) =
    Option.exists
      (fun (p : State.pane) -> Tmux.equal_session_id caller.session_id p.session_id)
      (Option.flat_map (State.find state) s.pane)
  in
  match matched (List.filter in_session states) with
  | Some r -> r
  | None -> (
      match matched states with
      | Some (Error m) -> Error (m ^ ", none in this tmux session")
      | Some (Ok (id, _)) ->
          Error
            (Printf.sprintf "%s (%s) is in another tmux session, not this one" to_
               (Run.string_of_id id))
      | None -> Error (Printf.sprintf "no agent session matches %S" to_))

let reaches ~dir ~caller id =
  Option.for_all
    (fun c ->
      Option.exists
        (fun (m : Run.meta) -> List.mem ~eq:Run.equal_id c (m.id :: Run.ancestors ~dir m))
        (Run.read_meta ~dir id))
    caller

let resolve ~dir ~state:({ agents; _ } as state : State.t) ~self ~caller recipient =
  let open Result.Infix in
  let caller = Option.map fst caller in
  let agents = List.map snd (Tmux.Pane_map.bindings agents) in
  let descendant address =
    let* ((id, target) as e) = resolve_target agents state ~self address in
    if reaches ~dir ~caller id then Ok e
    else Error (State.run_display_name state target ^ " is not this agent's descendant")
  in
  let* ((id, target) as e) =
    match recipient with
    | Named to_ -> resolve_target agents state ~self (Name to_)
    | Descendant to_ -> descendant (Name to_)
    | Descendant_run id -> descendant (Run id)
    | Parent session -> Result.map (fun s -> (session, s)) (Run.live_parent ~dir session)
  in
  if Option.exists (Run.equal_id id) caller then
    Error (State.run_display_name state target ^ " is this agent")
  else Ok e

let deliver ~dir ~caller ~state ~self spec (run_id, (target : Run.pi)) text =
  let name = State.run_display_name state target in
  let kind, id, reply_to =
    match spec with
    | Message -> (Msg.Message, None, "")
    | Reply ask -> (Msg.Reply, None, ask)
    | Ask id -> (Msg.Ask, id, "")
    | Notice -> (Msg.Notice, None, "")
    | Steer -> (Msg.Steer, None, "")
    | Interrupt -> (Msg.Interrupt, None, "")
    | Stop -> (Msg.Stop, None, "")
  in
  let tag = Msg.string_of_kind kind in
  let is_message = match spec with Message -> true | _ -> false in
  if (not is_message) && String.is_empty target.inbox then
    Error
      (Failed
         (Printf.sprintf
            "%s has no inbox to send a %s to; only a plain message can be sent as v0 text" name tag))
  else
    let from : Msg.from =
      match caller with
      | Some (id, s) ->
          { session = Run.string_of_id id; name = State.run_display_name state s; pane = self }
      | None -> { session = ""; name = ""; pane = self }
    in
    let envelope : Msg.envelope =
      { kind; id = Option.get_lazy Msg.new_id id; from; reply_to; text; run = ""; output = "" }
    in
    let run =
      match Run.read_meta ~dir run_id with
      | Some { kind = Agent; _ } -> Some run_id
      | Some { kind = Pi | Bash | Stream; _ } | None -> None
    in
    if is_message then
      Result.map_err
        (fun m -> Failed m)
        (Prompt.deliver_or_paste ~inbox:target.inbox
           ~payload:(Yojson.Safe.to_string (Msg.yojson_of_envelope envelope))
           ~pane:target.pane ~name ~run text)
    else
      match Msg.deliver_envelope ~path:target.inbox envelope with
      | Ok () -> Ok `Inbox
      | Error (Msg.Refused _) -> Error (Failed (Printf.sprintf "%s refused the %s" name tag))
      | Error (Msg.Unavailable _) -> Error (Unavailable (Prompt.not_accepting ~name ~run))
      | Error (Msg.Failed m) -> Error (Failed m)

let send ~dir ~self ~caller recipient spec text =
  let open Result.Infix in
  let not_sent r = Result.map_err (fun m -> Not_sent m) r in
  if String.is_empty text then Error No_text
  else if not (String.is_valid_utf_8 text) then Error (Not_sent "message is not valid UTF-8")
  else
    let* state = not_sent (State.read ~dir (Tmux.create ())) in
    let alternative = "use kido tool message_agent instead, which is one-way and needs no reply" in
    let* () =
      match (spec, caller) with
      | Ask _, None ->
          Error
            (Not_sent
               (Printf.sprintf
                  "no agent session is calling ($PI_SESSION_ID names none), so an answer could not \
                   be addressed back; nothing sent - %s"
                  alternative))
      | Ask _, Some (_, (s : Run.pi)) when String.is_empty s.inbox ->
          Error
            (Not_sent
               (Printf.sprintf
                  "%s has no inbox for an answer to arrive on, and only a long-lived process has \
                   one; nothing sent - %s"
                  (State.run_display_name state s) alternative))
      | _ -> Ok ()
    in
    let* ((id, target) as e) = not_sent (resolve ~dir ~state ~self ~caller recipient) in
    let name = State.run_display_name state target in
    let status =
      let open Option.Infix in
      let* pane = target.pane in
      let* p = State.find state pane in
      let+ (r : Tmux.Program_status.record) = Tmux.Program_status.root p.program_status in
      r.state
    in
    match (deliver ~dir ~caller ~state ~self spec e text, spec, status) with
    | Ok `Pasted, _, _ -> Ok (Printf.sprintf "pasted into %s's pane" name)
    | Ok `Inbox, Message, Some (Working _) ->
        let steerable = reaches ~dir ~caller:(Option.map fst caller) id in
        Ok
          (Printf.sprintf "queued for %s: it is running and reads this when its current turn ends%s"
             name
             (if steerable then "; to reach it now, use steer_subagent" else ""))
    | Ok `Inbox, _, _ -> Ok (Printf.sprintf "delivered to %s by inbox" name)
    | Error (Unavailable m | Failed m), _, _ -> Error (Not_sent m)

let head_within s max = Msg.valid_utf_8 (Msg.utf_8_prefix s max)

let parent_guidance =
  "\n\n\
   The child stays alive after it reports. End it with stop_run when you need nothing more from \
   it. To continue it, use message_agent."

let report_notice ~dir ~status run report =
  if status then head_within report Msg.max_notice_bytes
  else
    let budget = Msg.max_notice_bytes - String.length parent_guidance in
    match run with
    | None -> head_within report budget
    | Some id ->
        if String.length report <= budget then report
        else
          let suffix = "\n\nfull report: " ^ Run.report_path ~dir id in
          head_within report (budget - String.length suffix) ^ suffix

let notify_parent ~dir ~self ~caller ~warn ~parent ~run ~status text =
  match parent with
  | None ->
      Error
        (Not_sent "this session has no parent ($KIDO_AGENT_PARENT_SESSION is not set); nothing sent")
  | Some parent -> (
      let notice = report_notice ~dir ~status run text in
      match
        send ~dir ~self ~caller (Parent parent) Notice
          (if status then notice else notice ^ parent_guidance)
      with
      | Error e -> Error e
      | Ok sent ->
          if not status then
            Option.iter
              (fun id ->
                try Run.write_report ~dir id text
                with Unix.Unix_error (e, fn, arg) ->
                  warn
                    (Printf.sprintf
                       "keeping the whole report failed (%s); the parent got the notice, but kido \
                        runs will not name a report"
                       (Fs.unix_message e fn arg)))
              run;
          Ok sent)
