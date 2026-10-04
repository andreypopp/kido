open Tmux

type agent_info = {
  id : string;
  name : string;
  agent : State.agent;
  pane : string;
  window : string;
  status : State.status;
  activity : string;
  parent : string;
  depth : int;
  self : bool;
  cwd : string;
  can_message : bool; [@key "canMessage"]
  can_reply : bool; [@key "canReply"]
  model : string;
  since_report : int; [@key "sinceReport"]
  stalled : bool;
}
[@@deriving to_yojson]

let caller_pane panes self =
  Option.to_result (Printf.sprintf "pane %S not found" self) (Pane.find panes self)

let agent_title title =
  match String.chop_prefix ~pre:"π - " title with
  | Some t -> t
  | None ->
      let rec skip i =
        if i >= String.length title then i
        else
          let d = String.get_utf_8_uchar title i in
          let c = Uchar.to_int (Uchar.utf_decode_uchar d) in
          if
            (c < 0x80 && not (Char.Ascii.is_alphanum (Char.chr c)))
            || (c >= 0x80 && c <= 0xBF)
            || c = 0xD7 || c = 0xF7
            || (c >= 0x2000 && c <= 0x2BFF)
            || (c >= 0x2E00 && c <= 0x2E7F)
            || (c >= 0x3000 && c <= 0x303F)
            || (c >= 0xFE00 && c <= 0xFE0F)
            || c = 0xFFFD
            || (c >= 0x1F000 && c <= 0x1FAFF)
          then skip (i + Uchar.utf_decode_length d)
          else i
      in
      let i = skip 0 in
      String.sub title i (String.length title - i)

let display_name panes (s : State.session) =
  if not (String.is_empty s.title) then s.title
  else Option.map_or ~default:"" (fun (p : Pane.t) -> agent_title p.title) (Pane.find panes s.pane)

let per_pane live = List.map snd (State.String_map.bindings (State.by_pane live))

let in_session panes states session =
  List.filter
    (fun (_, (s : State.session)) ->
      String.equal session
        (Option.map_or ~default:"" (fun (p : Pane.t) -> p.session_id) (Pane.find panes s.pane)))
    states

let parent_edge (id, (s : State.session)) =
  match s.parent with Some p when not (String.equal p.session id) -> Some p.session | _ -> None

let is_ancestor parent_of ~ancestor target =
  let rec walk seen cur =
    match cur with
    | None -> false
    | Some cur when List.mem ~eq:String.equal cur seen -> false
    | Some cur ->
        String.equal cur ancestor
        || walk (cur :: seen) (List.assoc_opt ~eq:String.equal cur parent_of)
  in
  (not (String.equal ancestor target)) && walk [] (List.assoc_opt ~eq:String.equal target parent_of)

let can_reply ~dir id =
  match Result.to_opt (Subrun.parse_id id) |> Option.flat_map (Subrun.read_meta ~dir) with
  | Some m -> List.is_empty m.tools || List.mem ~eq:String.equal "message_agent" m.tools
  | None -> true

let agents ~dir ~threshold ~self ~session ~panes ~states =
  let open Result.Infix in
  let+ session =
    if not (String.is_empty session) then Ok session
    else
      match Pane.find panes self with
      | Some p -> Ok p.session_id
      | None ->
          Error
            (Printf.sprintf
               "no tmux session for pane %S; pass --session\n\
                usage: kido tool list_runs [--session ID] [--json]"
               self)
  in
  let wake = State.wake ~dir and now = Timestamp.now () in
  let scoped = in_session panes states session in
  let parent e =
    match parent_edge e with Some p when List.mem_assoc ~eq:String.equal p scoped -> p | _ -> ""
  in
  List.sort
    (fun (a, (sa : State.session)) (b, (sb : State.session)) ->
      match Float.compare sa.ts sb.ts with 0 -> String.compare a b | c -> c)
    scoped
  |> Tree.order ~id:fst ~parent
  |> List.map (fun (id, (s : State.session)) ->
      let p = Pane.find panes s.pane in
      {
        id;
        name = display_name panes s;
        agent = s.agent;
        pane = s.pane;
        window = Option.map_or ~default:"" (fun (p : Pane.t) -> p.window_id) p;
        status = s.status;
        activity = s.activity;
        parent = Option.map_or ~default:"" (fun (p : State.parent) -> p.session) s.parent;
        depth = s.depth;
        self = String.equal s.pane self;
        cwd = Option.map_or ~default:"" (fun (p : Pane.t) -> p.current_path) p;
        can_message = not (String.is_empty s.inbox);
        can_reply = (not (String.is_empty s.inbox)) && can_reply ~dir id;
        model = s.model;
        since_report = Float.to_int (now -. s.ts);
        stalled = State.stalled_since ~threshold ~wake ~now s;
      })

type row =
  | Peer of agent_info
  | Parent of agent_info
  | Own of { run : Runs.info; agent : agent_info option; window : string }

let list_runs ~dir ~threshold ~self ~session =
  let open Result.Infix in
  let* panes = Exec.list_panes () in
  let+ agents =
    agents ~dir ~threshold ~self ~session ~panes ~states:(per_pane (State.load_live ~dir))
  in
  let caller = List.find_opt (fun a -> a.self) agents in
  let own = Option.map_or ~default:"" (fun a -> a.id) caller in
  let parent = Option.map_or ~default:"" (fun a -> a.parent) caller in
  let visible =
    List.filter_map
      (fun a ->
        if a.self then None
        else if (not (String.is_empty parent)) && String.equal a.id parent then Some (Parent a)
        else if String.equal parent a.parent then
          if String.is_empty parent then Some (Peer a)
          else
            match
              Result.to_opt (Subrun.parse_id a.id) |> Option.flat_map (Subrun.read_meta ~dir)
            with
            | Some ({ kind = Agent; _ } as m)
              when Option.is_none (Subrun.effective_outcome ~dir m.id ~pid:m.pid) ->
                Some (Peer a)
            | _ -> None
        else None)
      agents
  in
  let ended = ref 0 in
  let runs =
    if String.is_empty own then []
    else
      Runs.list ~parent_session:own ~dir ()
      |> List.filter (fun (r : Runs.info) ->
          match r.outcome with
          | None -> true
          | Some _ ->
              incr ended;
              !ended <= 20)
      |> List.map (fun (r : Runs.info) ->
          Own
            {
              run = r;
              agent =
                (if Option.is_some r.outcome then None
                 else
                   List.find_opt (fun a -> String.equal a.id (Subrun.string_of_id r.meta.id)) agents);
              window =
                Option.map_or ~default:""
                  (fun (p : Pane.t) -> p.window_id)
                  (Pane.find panes r.meta.pane);
            })
  in
  visible @ runs

let row_to_yojson row =
  let agent_fields a = match agent_info_to_yojson a with `Assoc fields -> fields | _ -> [] in
  let fields, kind, relationship, extra =
    match row with
    | Peer a ->
        (agent_fields a, (if String.is_empty a.parent then "agent" else "subagent"), "peer", [])
    | Parent a ->
        (agent_fields a, (if String.is_empty a.parent then "agent" else "subagent"), "parent", [])
    | Own { run = r; agent = a; window } ->
        let m = r.meta in
        let fields =
          match a with
          | Some a -> agent_fields a
          | None ->
              [
                ("id", `String (Subrun.string_of_id m.id));
                ("name", `String m.name);
                ("pane", `String m.pane);
                ("window", `String window);
                ("parent", `String m.parent_session);
                ("cwd", `String m.cwd);
                ("canMessage", `Bool false);
                ("canReply", `Bool false);
              ]
        in
        let extra =
          [
            ("run", `String (Subrun.string_of_id m.id));
            ("state", `String (if Option.is_none r.outcome then "running" else "ended"));
            ("startedAt", Timestamp.to_yojson m.started_at);
          ]
          @ Option.map_or ~default:[]
              (fun o -> [ ("outcome", Subrun.outcome_to_yojson o) ])
              r.outcome
        in
        (fields, (match m.kind with Agent -> "subagent" | Bash | Stream -> "bash"), "own", extra)
  in
  `Assoc (fields @ [ ("kind", `String kind); ("relationship", `String relationship) ] @ extra)

let table rows =
  let columns =
    String.split_on_char ' '
      "id name kind relationship status activity canReply model pane window stalled sinceReport \
       parent depth cwd run state startedAt"
  in
  String.split_on_char ' '
    "ID NAME KIND RELATIONSHIP STATUS ACTIVITY CAN_REPLY MODEL PANE WINDOW STALLED SINCE PARENT \
     DEPTH CWD RUN STATE STARTED OUTCOME DETAIL"
  :: List.map
       (fun row ->
         let json = row_to_yojson row in
         let open Yojson.Safe.Util in
         let value json k =
           match member k json with
           | `String s -> s
           | `Int n -> string_of_int n
           | `Bool b -> string_of_bool b
           | _ -> ""
         in
         List.map (value json) columns
         @ (match member "outcome" json with
           | `Null -> [ ""; "" ]
           | o -> List.map (value o) [ "result"; "text" ]))
       rows
