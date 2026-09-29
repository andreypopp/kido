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

let find_pane panes id = List.find_opt (fun (p : Pane.t) -> String.equal p.pane_id id) panes

let display_name panes (s : State.session) =
  if not (String.is_empty s.title) then s.title
  else
    Option.map_or ~default:""
      (fun (p : Pane.t) -> State.agent_title p.title)
      (find_pane panes s.pane)

let per_pane live = List.map snd (State.Panes.bindings (State.by_pane live))

let in_session panes states session =
  List.filter
    (fun (_, (s : State.session)) ->
      String.equal session
        (Option.map_or ~default:"" (fun (p : Pane.t) -> p.session_id) (find_pane panes s.pane)))
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

let can_reply ~runs id =
  match Result.to_opt (Subrun.parse_id id) |> Option.flat_map (Subrun.read_meta ~dir:runs) with
  | Some m -> List.is_empty m.tools || List.mem ~eq:String.equal "message_agent" m.tools
  | None -> true

let build ~runs ~threshold ~wake ~now states panes ~session ~self =
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
      let p = find_pane panes s.pane in
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
        can_reply = (not (String.is_empty s.inbox)) && can_reply ~runs id;
        model = s.model;
        since_report = Float.to_int (now -. s.ts);
        stalled = State.stalled_since ~threshold ~wake ~now s;
      })

let width s = String.fold (fun n c -> if Char.code c land 0xC0 = 0x80 then n else n + 1) 0 s

let table rows =
  let widths =
    List.fold_left
      (fun ws row -> List.map2 (fun w c -> max w (width c + 2)) ws row)
      (List.map (Fun.const 0) (List.hd rows))
      rows
  in
  List.iter
    (fun row ->
      let cells = List.combine widths row in
      List.iteri
        (fun i (w, c) ->
          print_string c;
          if i < List.length cells - 1 then print_string (String.make (w - width c) ' '))
        cells;
      print_newline ())
    rows

let list_agents ~dir ~threshold ~self ~panes ~session ~json =
  let panes = Lazy.force panes in
  let states = per_pane (State.load_live ~dir) in
  let session =
    if not (String.is_empty session) then session
    else
      match find_pane panes self with
      | Some p -> p.session_id
      | None ->
          failwith
            (Printf.sprintf
               "no tmux session for pane %S; pass --session\n\
                usage: kido list_agents [--session ID] [--json]"
               self)
  in
  let agents =
    build ~runs:(Filename.concat dir "runs") ~threshold ~wake:(State.wake ~dir)
      ~now:(Timestamp.now ()) states panes ~session ~self
  in
  if json then print_endline (Yojson.Safe.to_string (`List (List.map agent_info_to_yojson agents)))
  else
    table
      (String.split_on_char ' '
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
           agents);
  0
