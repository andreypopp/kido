type recipient =
  | Named of string
  | Descendant of string
  | Descendant_run of Run.id
  | Parent of Run.id

type address = Name of string | Run of Run.id
type spec = Message | Reply of string | Ask of string option | Notice | Steer | Interrupt | Stop
type failure = Unavailable of string | Failed of string
type send_error = No_text | Not_sent of string

let decide ~panes to_ by = function
  | [] -> None
  | [ e ] -> Some (Ok e)
  | many ->
      List.map
        (fun (id, s) -> Printf.sprintf "%s (%s)" (Run.string_of_id id) (Run.display_name panes s))
        many
      |> List.sort String.compare |> String.concat ", "
      |> Printf.sprintf "%S matches several agents by %s: %s" to_ by
      |> fun m -> Some (Error m)

let match_target ~panes sessions to_ =
  let named (_, (s : Run.pi)) =
    (not (String.is_empty s.name)) && String.equal_caseless s.name to_
  in
  match decide ~panes to_ "name" (List.filter named sessions) with
  | Some r -> Some r
  | None -> (
      match List.find_opt (fun (id, _) -> String.equal (Run.string_of_id id) to_) sessions with
      | Some e -> Some (Ok e)
      | None ->
          decide ~panes to_ "id"
            (List.filter (fun (id, _) -> String.prefix ~pre:to_ (Run.string_of_id id)) sessions))

let resolve_target states panes ~self address =
  let open Result.Infix in
  let to_, matched =
    match address with
    | Name to_ -> (to_, fun states -> match_target ~panes states to_)
    | Run id ->
        ( Run.string_of_id id,
          fun states -> Option.map (fun s -> Ok (id, s)) (List.assoc_opt ~eq:Run.equal_id id states)
        )
  in
  let* caller = Tmux_pane.caller_pane panes self in
  let in_session (_, (s : Run.pi)) =
    Option.exists
      (fun (p : Tmux_pane.t) -> Tmux.equal_session_id caller.session_id p.session_id)
      (Option.flat_map (Tmux_pane.find panes) s.pane)
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

let resolve ~dir ~panes ~self ~caller recipient =
  let open Result.Infix in
  let caller = Option.map fst caller in
  let agents = List.map snd (Tmux.Pane_map.bindings (Run.agents (Run.marked ~dir panes))) in
  let descendant address =
    let* ((id, target) as e) = resolve_target agents panes ~self address in
    if reaches ~dir ~caller id then Ok e
    else Error (Run.display_name panes target ^ " is not this agent's descendant")
  in
  let* ((id, target) as e) =
    match recipient with
    | Named to_ -> resolve_target agents panes ~self (Name to_)
    | Descendant to_ -> descendant (Name to_)
    | Descendant_run id -> descendant (Run id)
    | Parent session -> Result.map (fun s -> (session, s)) (Run.live_parent ~dir session)
  in
  if Option.exists (Run.equal_id id) caller then
    Error (Run.display_name panes target ^ " is this agent")
  else Ok e

let deliver ~dir ~caller ~panes ~self spec (run_id, (target : Run.pi)) text =
  let name = Run.display_name panes target in
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
          { session = Run.string_of_id id; name = Run.display_name panes s; pane = self }
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
    let* panes = not_sent (Tmux_pane.list_panes (Tmux.create ())) in
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
                  (Run.display_name panes s) alternative))
      | _ -> Ok ()
    in
    let* ((id, target) as e) = not_sent (resolve ~dir ~panes ~self ~caller recipient) in
    let name = Run.display_name panes target in
    let status =
      Option.flat_map (Tmux_pane.find panes) target.pane
      |> Option.flat_map (fun (p : Tmux_pane.t) -> Tmux.Program_status.root p.program_status)
      |> Option.map (fun (r : Tmux.Program_status.record) -> r.state)
    in
    match (deliver ~dir ~caller ~panes ~self spec e text, spec, status) with
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

let report_notice ~warn ~dir run report =
  if String.length report <= Msg.max_notice_bytes then report
  else
    match run with
    | None -> head_within report Msg.max_notice_bytes
    | Some id -> (
        match Run.write_report ~dir id report with
        | () ->
            let suffix = "\n\nfull report: " ^ Run.report_path ~dir id in
            head_within report (Msg.max_notice_bytes - String.length suffix) ^ suffix
        | exception Unix.Unix_error (e, fn, arg) ->
            warn
              (Printf.sprintf "keeping the whole report failed (%s); sending a truncated one"
                 (Fs.unix_message e fn arg));
            head_within report Msg.max_notice_bytes)

let notify_parent ~dir ~self ~caller ~warn ~parent ~run text =
  match parent with
  | None ->
      Error
        (Not_sent "this session has no parent ($KIDO_AGENT_PARENT_SESSION is not set); nothing sent")
  | Some parent ->
      send ~dir ~self ~caller (Parent parent) Notice (report_notice ~warn ~dir run text)
