type recipient =
  | Named of string
  | Descendant of string
  | Descendant_run of Subrun.id
  | Parent of string

type address = Name of string | Run of Subrun.id
type spec = { kind : Msg.kind; reply_to : string; id : string }
type failure = Unavailable of string | Failed of string
type send_error = No_text | Not_sent of string

let decide ~panes to_ by = function
  | [] -> None
  | [ e ] -> Some (Ok e)
  | many ->
      List.map (fun (id, s) -> Printf.sprintf "%s (%s)" id (List_runs.display_name panes s)) many
      |> List.sort String.compare |> String.concat ", "
      |> Printf.sprintf "%S matches several agents by %s: %s" to_ by
      |> fun m -> Some (Error m)

let match_target ~panes sessions to_ =
  let named (_, s) =
    let name = List_runs.display_name panes s in
    (not (String.is_empty name)) && String.equal_caseless name to_
  in
  match decide ~panes to_ "name" (List.filter named sessions) with
  | Some r -> Some r
  | None -> (
      match List.find_opt (fun (id, _) -> String.equal id to_) sessions with
      | Some e -> Some (Ok e)
      | None ->
          decide ~panes to_ "id" (List.filter (fun (id, _) -> String.prefix ~pre:to_ id) sessions))

let resolve_target states panes ~self address =
  let open Result.Infix in
  let to_, matched =
    match address with
    | Name to_ -> (to_, fun states -> match_target ~panes states to_)
    | Run id ->
        let id = Subrun.string_of_id id in
        ( id,
          fun states -> Option.map (fun s -> Ok (id, s)) (List.assoc_opt ~eq:String.equal id states)
        )
  in
  let* caller = List_runs.caller_pane panes self in
  match matched (List_runs.in_session panes states caller.session_id) with
  | Some r -> r
  | None -> (
      match matched states with
      | Some (Error m) -> Error (m ^ ", none in this tmux session")
      | Some (Ok (id, _)) ->
          Error (Printf.sprintf "%s (%s) is in another tmux session, not this one" to_ id)
      | None -> Error (Printf.sprintf "no agent session matches %S" to_))

let reaches states panes ~self id =
  match List.find_opt (fun (_, (s : State.session)) -> String.equal s.pane self) states with
  | None -> Ok true
  | Some (caller, _) when String.equal caller id -> Ok true
  | Some (caller, _) ->
      Result.map
        (fun (p : Tmux.Pane.t) ->
          let parent_of =
            List.filter_map
              (fun e -> Option.map (fun p -> (fst e, p)) (List_runs.parent_edge e))
              (List_runs.in_session panes states p.session_id)
          in
          List_runs.is_ancestor parent_of ~ancestor:caller id)
        (List_runs.caller_pane panes self)

let descendant_target states panes ~self to_ =
  let open Result.Infix in
  let* ((id, target) as e) = resolve_target states panes ~self to_ in
  let* reached = reaches states panes ~self id in
  if reached then Ok e
  else Error (List_runs.display_name panes target ^ " is not this agent's descendant")

let resolve ~live ~panes ~self recipient =
  let open Result.Infix in
  let* ((_, target) as e) =
    match recipient with
    | Named to_ -> resolve_target (List_runs.per_pane live) panes ~self (Name to_)
    | Descendant to_ -> descendant_target (List_runs.per_pane live) panes ~self (Name to_)
    | Descendant_run id -> descendant_target (List_runs.per_pane live) panes ~self (Run id)
    | Parent session -> Result.map (fun s -> (session, s)) (Msg.live_parent live session)
  in
  if String.equal target.pane self then
    Error (List_runs.display_name panes target ^ " is this agent")
  else Ok e

let deliver ~states ~panes ~self spec (target : State.session) text =
  let name = List_runs.display_name panes target in
  let kind = Msg.string_of_kind spec.kind in
  let is_message = match spec.kind with Message -> true | _ -> false in
  if (not is_message) && String.is_empty target.inbox then
    Error
      (Failed
         (Printf.sprintf
            "%s has no inbox to send a %s to; only a plain message can be sent as v0 text" name kind))
  else
    let from : Msg.from =
      match State.String_map.find_opt self states with
      | Some (id, (s : State.session)) -> { session = id; name = s.title; pane = self }
      | None -> { session = ""; name = ""; pane = self }
    in
    let payload =
      if String.is_empty target.inbox then text
      else
        Yojson.Safe.to_string
          (Msg.envelope_to_yojson
             {
               kind = spec.kind;
               id = (if String.is_empty spec.id then Msg.new_id () else spec.id);
               from;
               reply_to = spec.reply_to;
               text;
               run = "";
               output = "";
             })
    in
    let run = Option.flat_map (fun (p : Tmux.Pane.t) -> p.run) (Tmux.Pane.find panes target.pane) in
    if is_message then
      Result.map_err
        (fun m -> Failed m)
        (Prompt.deliver_or_paste ~inbox:target.inbox ~payload ~pane:target.pane ~name ~run text)
    else
      match Msg.deliver ~path:target.inbox payload with
      | Ok () -> Ok `Inbox
      | Error (Msg.Refused _) -> Error (Failed (Printf.sprintf "%s refused the %s" name kind))
      | Error (Msg.Unavailable _) -> Error (Unavailable (Prompt.not_accepting ~name ~run))
      | Error (Msg.Failed m) -> Error (Failed m)

let send ~dir ~self recipient spec text =
  let open Result.Infix in
  let not_sent r = Result.map_err (fun m -> Not_sent m) r in
  if String.is_empty text then Error No_text
  else if not (String.is_valid_utf_8 text) then Error (Not_sent "message is not valid UTF-8")
  else
    let live = State.load_live ~dir in
    let states = State.by_pane live in
    let* panes = not_sent (Tmux.Exec.list_panes ()) in
    let alternative = "use kido tool message_agent instead, which is one-way and needs no reply" in
    let* () =
      match (spec.kind, State.String_map.find_opt self states) with
      | Ask, None ->
          Error
            (Not_sent
               (Printf.sprintf
                  "no live agent session on this pane (%s), so an answer could not be addressed \
                   back here; nothing sent - %s"
                  self alternative))
      | Ask, Some (_, caller) when String.is_empty caller.inbox ->
          Error
            (Not_sent
               (Printf.sprintf
                  "%s has no inbox for an answer to arrive on, and only a long-lived process has \
                   one; nothing sent - %s"
                  (List_runs.display_name panes caller)
                  alternative))
      | _ -> Ok ()
    in
    let* id, target = not_sent (resolve ~live ~panes ~self recipient) in
    let name = List_runs.display_name panes target in
    match (deliver ~states ~panes ~self spec target text, spec.kind, target.status) with
    | Ok `Pasted, _, _ -> Ok (Printf.sprintf "pasted into %s's pane" name)
    | Ok `Inbox, Message, (State.Running | Compacting) ->
        let steerable =
          Result.get_or ~default:false (reaches (List_runs.per_pane live) panes ~self id)
        in
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
        match Subrun.write_report ~dir id report with
        | () ->
            let suffix = "\n\nfull report: " ^ Subrun.report_path ~dir id in
            head_within report (Msg.max_notice_bytes - String.length suffix) ^ suffix
        | exception Unix.Unix_error (e, fn, arg) ->
            warn
              (Printf.sprintf "keeping the whole report failed (%s); sending a truncated one"
                 (Fs.unix_message e fn arg));
            head_within report Msg.max_notice_bytes)

let notify_parent ~dir ~self ~warn ~parent ~run text =
  if String.is_empty parent then
    Error
      (Not_sent "this session has no parent ($KIDO_AGENT_PARENT_SESSION is not set); nothing sent")
  else
    let run = Result.to_opt (Subrun.parse_id run) in
    send ~dir ~self (Parent parent)
      { kind = Notice; reply_to = ""; id = "" }
      (report_notice ~warn ~dir run text)
