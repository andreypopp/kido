type recipient = Named of string | Descendant of string | Parent of string
type spec = { kind : Msg.kind; recipient : recipient; reply_to : string; id : string }

let fail fmt = Printf.ksprintf failwith fmt

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

let caller_pane panes self =
  match List_agents.find_pane panes self with Some p -> p | None -> fail "pane %S not found" self

let resolve_target states panes ~self to_ =
  let caller = caller_pane panes self in
  match match_target ~panes (List_agents.in_session panes states caller.session_id) to_ with
  | Some (Ok e) -> e
  | Some (Error m) -> failwith m
  | None -> (
      match match_target ~panes states to_ with
      | Some (Error m) -> fail "%s, none in this tmux session" m
      | Some (Ok (id, _)) -> fail "%s (%s) is in another tmux session, not this one" to_ id
      | None -> fail "no agent session matches %S" to_)

let reaches states panes ~self id =
  match List.find_opt (fun (_, (s : State.session)) -> String.equal s.pane self) states with
  | None -> true
  | Some (caller, _) ->
      String.equal caller id
      ||
      let parent_of =
        List.filter_map
          (fun e -> Option.map (fun p -> (fst e, p)) (List_agents.parent_edge e))
          (List_agents.in_session panes states (caller_pane panes self).session_id)
      in
      List_agents.is_ancestor parent_of ~ancestor:caller id

let descendant_target states panes ~self to_ =
  let ((id, target) as e) = resolve_target states panes ~self to_ in
  let name = List_agents.display_name panes target in
  if String.equal target.pane self then fail "%s is this agent" name;
  if not (reaches states panes ~self id) then fail "%s is not this agent's descendant" name;
  e

let resolve ~live ~panes ~self = function
  | Named to_ -> resolve_target (List_agents.per_pane live) panes ~self to_
  | Descendant to_ -> descendant_target (List_agents.per_pane live) panes ~self to_
  | Parent session -> (
      match List.assoc_opt ~eq:String.equal session live with
      | Some s -> (session, s)
      | None -> fail "no live process holds session %S; the parent is gone, nothing sent" session)

let deliver ~states ~panes ~self ~paste spec (target : State.session) text =
  let name = List_agents.display_name panes target in
  let kind = Msg.string_of_kind spec.kind in
  let is_message = match spec.kind with Message -> true | _ -> false in
  if (not is_message) && String.is_empty target.inbox then
    fail "%s has no inbox to send a %s to; only a plain message can be sent as v0 text" name kind;
  let from : Msg.from =
    match State.Panes.find_opt self states with
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
    Ok (Prompt.deliver_or_paste ~paste ~inbox:target.inbox ~payload ~pane:target.pane text)
  else
    match Msg.deliver ~path:target.inbox payload with
    | Ok () -> Ok `Inbox
    | Error (Refused _) -> Error (`Failed (Printf.sprintf "%s refused the %s" name kind))
    | Error (Unavailable _ as e) ->
        Error
          (`Unavailable
             (Printf.sprintf
                "%s is not listening on its inbox; a %s cannot fall back to a paste: %s" name kind
                (Msg.string_of_error e)))
    | Error (Failed m) -> Error (`Failed m)

let send ~dir ~self ~panes ~paste spec text =
  let text = String.chop_suffix ~suf:"\n" text |> Option.get_or ~default:text in
  if String.is_empty text then begin
    prerr_endline "no message given";
    1
  end
  else begin
    if not (String.is_valid_utf_8 text) then failwith "message is not valid UTF-8";
    let live = State.load_live ~dir in
    let states = State.by_pane live in
    let panes = Lazy.force panes in
    (match spec.kind with
    | Ask -> (
        let alternative = "use kido message_agent instead, which is one-way and needs no reply" in
        match State.Panes.find_opt self states with
        | None ->
            fail
              "no live agent session on this pane (%s), so an answer could not be addressed back \
               here; nothing sent - %s"
              self alternative
        | Some (_, caller) when String.is_empty caller.inbox ->
            fail
              "%s has no inbox for an answer to arrive on, and only a long-lived process has one; \
               nothing sent - %s"
              (List_agents.display_name panes caller)
              alternative
        | Some _ -> ())
    | _ -> ());
    let _, target = resolve ~live ~panes ~self spec.recipient in
    let name = List_agents.display_name panes target in
    if String.equal target.pane self then fail "%s is this agent" name;
    (match deliver ~states ~panes ~self ~paste spec target text with
    | Ok `Pasted -> Printf.printf "pasted into %s's pane\n" name
    | Ok `Inbox -> Printf.printf "delivered to %s by inbox\n" name
    | Error (`Unavailable m | `Failed m) -> failwith m);
    0
  end

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
    let continuation i = Char.code s.[i] land 0xC0 = 0x80 in
    let rec back n = if n > 0 && continuation (n - 1) then back (n - 1) else n in
    let n = back max in
    let n = if n > 0 && Char.code s.[n - 1] land 0xC0 = 0xC0 then n - 1 else n in
    to_valid_utf_8 (String.sub s 0 n)

let report_notice ~runs run report =
  if String.length report <= max_report_bytes then report
  else
    match run with
    | None -> head_within report max_report_bytes
    | Some id -> (
        match Subrun.write_report ~dir:runs id report with
        | () ->
            let suffix = "\n\nfull report: " ^ Subrun.report_path ~dir:runs id in
            head_within report (max_report_bytes - String.length suffix) ^ suffix
        | exception Unix.Unix_error (e, _, _) ->
            Cli.error "notify_parent"
              (Printf.sprintf "keeping the whole report failed (%s); sending a truncated one"
                 (Unix.error_message e));
            head_within report max_report_bytes)

let notify_parent ~dir ~self ~panes ~paste ~parent ~run text =
  if String.is_empty parent then
    failwith "this session has no parent ($KIDO_AGENT_PARENT_SESSION is not set); nothing sent";
  let run = Result.to_opt (Subrun.parse_id run) in
  let report = String.chop_suffix ~suf:"\n" text |> Option.get_or ~default:text in
  send ~dir ~self ~panes ~paste
    { kind = Notice; recipient = Parent parent; reply_to = ""; id = "" }
    (report_notice ~runs:(Filename.concat dir "runs") run report)
