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

let symbol u =
  let c = Uchar.to_int u in
  (c < 0x80 && not (Char.Ascii.is_alphanum (Char.chr c)))
  || (c >= 0x80 && c <= 0xBF)
  || c = 0xD7 || c = 0xF7
  || (c >= 0x2000 && c <= 0x2BFF)
  || (c >= 0x2E00 && c <= 0x2E7F)
  || (c >= 0x3000 && c <= 0x303F)
  || (c >= 0xFE00 && c <= 0xFE0F)
  || c = 0xFFFD
  || (c >= 0x1F000 && c <= 0x1FAFF)

let agent_title title =
  match String.chop_prefix ~pre:"π - " title with
  | Some t -> t
  | None ->
      let rec skip i =
        if i >= String.length title then i
        else
          let d = String.get_utf_8_uchar title i in
          if symbol (Uchar.utf_decode_uchar d) then skip (i + Uchar.utf_decode_length d) else i
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

let list_agents ~dir ~threshold ~self ~session =
  let open Result.Infix in
  let* panes = Exec.list_panes () in
  let states = per_pane (State.load_live ~dir) in
  let+ session =
    if not (String.is_empty session) then Ok session
    else
      match Pane.find panes self with
      | Some p -> Ok p.session_id
      | None ->
          Error
            (Printf.sprintf
               "no tmux session for pane %S; pass --session\n\
                usage: kido list_agents [--session ID] [--json]"
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
  |> List.map (fun ((id, (s : State.session)) as e) ->
      let p = Pane.find panes s.pane in
      {
        id;
        name = display_name panes s;
        agent = s.agent;
        pane = s.pane;
        window = Option.map_or ~default:"" (fun (p : Pane.t) -> p.window_id) p;
        status = s.status;
        activity = s.activity;
        parent = parent e;
        depth = s.depth;
        self = String.equal s.pane self;
        cwd = Option.map_or ~default:"" (fun (p : Pane.t) -> p.current_path) p;
        can_message = not (String.is_empty s.inbox);
        can_reply = (not (String.is_empty s.inbox)) && can_reply ~dir id;
        model = s.model;
        since_report = Float.to_int (now -. s.ts);
        stalled = State.stalled_since ~threshold ~wake ~now s;
      })

let table agents =
  String.split_on_char ' '
    "ID NAME AGENT MODEL PANE WINDOW STATUS STALLED ACTIVITY SINCE PARENT DEPTH SELF CWD"
  :: List.map
       (fun a ->
         [
           a.id;
           a.name;
           State.string_of_agent a.agent;
           a.model;
           a.pane;
           a.window;
           State.string_of_status a.status;
           (if a.stalled then "stalled" else "");
           a.activity;
           string_of_int a.since_report;
           a.parent;
           string_of_int a.depth;
           (if a.self then "*" else "");
           a.cwd;
         ])
       agents
