type recipient = Named of string | Descendant of string | Parent of string
type spec = { kind : Msg.kind; reply_to : string; id : string }
type failure = Unavailable of string | Failed of string
type send_error = No_text | Not_sent of string

let decide ~panes to_ by = function
  | [] -> None
  | [ e ] -> Some (Ok e)
  | many ->
      List.map (fun (id, s) -> Printf.sprintf "%s (%s)" id (List_agents.display_name panes s)) many
      |> List.sort String.compare |> String.concat ", "
      |> Printf.sprintf "%S matches several agents by %s: %s" to_ by
      |> fun m -> Some (Error m)

let match_target ~panes sessions to_ =
  let named (_, s) =
    let name = List_agents.display_name panes s in
    (not (String.is_empty name)) && String.equal_caseless name to_
  in
  match decide ~panes to_ "name" (List.filter named sessions) with
  | Some r -> Some r
  | None -> (
      match List.find_opt (fun (id, _) -> String.equal id to_) sessions with
      | Some e -> Some (Ok e)
      | None ->
          decide ~panes to_ "id" (List.filter (fun (id, _) -> String.prefix ~pre:to_ id) sessions))

let resolve_target states panes ~self to_ =
  let open Result.Infix in
  let* caller = List_agents.caller_pane panes self in
  match match_target ~panes (List_agents.in_session panes states caller.session_id) to_ with
  | Some r -> r
  | None -> (
      match match_target ~panes states to_ with
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
              (fun e -> Option.map (fun p -> (fst e, p)) (List_agents.parent_edge e))
              (List_agents.in_session panes states p.session_id)
          in
          List_agents.is_ancestor parent_of ~ancestor:caller id)
        (List_agents.caller_pane panes self)

let descendant_target states panes ~self to_ =
  let open Result.Infix in
  let* ((id, target) as e) = resolve_target states panes ~self to_ in
  let name = List_agents.display_name panes target in
  if String.equal target.pane self then Error (name ^ " is this agent")
  else
    let* reached = reaches states panes ~self id in
    if reached then Ok e else Error (name ^ " is not this agent's descendant")

let resolve ~live ~panes ~self = function
  | Named to_ -> resolve_target (List_agents.per_pane live) panes ~self to_
  | Descendant to_ -> descendant_target (List_agents.per_pane live) panes ~self to_
  | Parent session -> (
      match List.assoc_opt ~eq:String.equal session live with
      | Some s -> Ok (session, s)
      | None ->
          Error
            (Printf.sprintf "no live process holds session %S; the parent is gone, nothing sent"
               session))

let deliver ~states ~panes ~self ~paste spec (target : State.session) text =
  let name = List_agents.display_name panes target in
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
               v = Msg.v1;
               kind = spec.kind;
               id = (if String.is_empty spec.id then Msg.new_id () else spec.id);
               from;
               reply_to = spec.reply_to;
               text;
               run = "";
               output = "";
             })
    in
    if is_message then
      Result.map_err
        (fun m -> Failed m)
        (Prompt.deliver_or_paste ~paste ~inbox:target.inbox ~payload ~pane:target.pane text)
    else
      match Msg.deliver ~path:target.inbox payload with
      | Ok () -> Ok `Inbox
      | Error (Msg.Refused _) -> Error (Failed (Printf.sprintf "%s refused the %s" name kind))
      | Error (Msg.Unavailable _ as e) ->
          Error
            (Unavailable
               (Printf.sprintf
                  "%s is not listening on its inbox; a %s cannot fall back to a paste: %s" name kind
                  (Msg.string_of_error e)))
      | Error (Msg.Failed m) -> Error (Failed m)

let send ~dir ~self ~panes ~paste recipient spec text =
  let open Result.Infix in
  let text = String.chop_suffix ~suf:"\n" text |> Option.get_or ~default:text in
  let not_sent r = Result.map_err (fun m -> Not_sent m) r in
  if String.is_empty text then Error No_text
  else if not (String.is_valid_utf_8 text) then Error (Not_sent "message is not valid UTF-8")
  else
    let live = State.load_live ~dir in
    let states = State.by_pane live in
    let* panes = not_sent (Lazy.force panes) in
    let alternative = "use kido message_agent instead, which is one-way and needs no reply" in
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
                  (List_agents.display_name panes caller)
                  alternative))
      | _ -> Ok ()
    in
    let* _, target = not_sent (resolve ~live ~panes ~self recipient) in
    let name = List_agents.display_name panes target in
    if String.equal target.pane self then Error (Not_sent (name ^ " is this agent"))
    else
      match deliver ~states ~panes ~self ~paste spec target text with
      | Ok `Pasted -> Ok (Printf.sprintf "pasted into %s's pane" name)
      | Ok `Inbox -> Ok (Printf.sprintf "delivered to %s by inbox" name)
      | Error (Unavailable m | Failed m) -> Error (Not_sent m)

let max_report_bytes = 4000

let to_valid_utf_8 s =
  let b = Buffer.create (String.length s) in
  let rec go i bad =
    if i < String.length s then begin
      let d = String.get_utf_8_uchar s i in
      let n = Uchar.utf_decode_length d in
      let valid = Uchar.utf_decode_is_valid d in
      if valid then Buffer.add_string b (String.sub s i n)
      else if not bad then Buffer.add_string b "\u{FFFD}";
      go (i + n) (not valid)
    end
  in
  go 0 false;
  Buffer.contents b

let head_within s max =
  if max <= 0 then ""
  else if String.length s <= max then s
  else
    let rec boundary n =
      if n > 0 && Char.code s.[n] land 0xC0 = 0x80 then boundary (n - 1) else n
    in
    to_valid_utf_8 (String.sub s 0 (boundary max))

let report_notice ~warn ~runs run report =
  if String.length report <= max_report_bytes then report
  else
    match run with
    | None -> head_within report max_report_bytes
    | Some id -> (
        match Subrun.write_report ~dir:runs id report with
        | () ->
            let suffix = "\n\nfull report: " ^ Subrun.report_path ~dir:runs id in
            head_within report (max_report_bytes - String.length suffix) ^ suffix
        | exception Unix.Unix_error (e, fn, arg) ->
            warn
              (Printf.sprintf "keeping the whole report failed (%s); sending a truncated one"
                 (Fs.unix_message e fn arg));
            head_within report max_report_bytes)

let notify_parent ~dir ~self ~panes ~paste ~warn ~parent ~run text =
  if String.is_empty parent then
    Error
      (Not_sent "this session has no parent ($KIDO_AGENT_PARENT_SESSION is not set); nothing sent")
  else
    let run = Result.to_opt (Subrun.parse_id run) in
    let report = String.chop_suffix ~suf:"\n" text |> Option.get_or ~default:text in
    send ~dir ~self ~panes ~paste (Parent parent)
      { kind = Notice; reply_to = ""; id = "" }
      (report_notice ~warn ~runs:(Filename.concat dir "runs") run report)
