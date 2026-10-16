open Tmux

type status = Tmux.Program_status.state option

let yojson_of_status (state : status) =
  `String
    (match state with
    | None -> "unknown"
    | Some Idle -> "idle"
    | Some (Working _) -> "working"
    | Some (Blocked _) -> "blocked"
    | Some Done -> "done"
    | Some Error -> "error")

type agent_info = {
  id : string;
  name : string;
  named : bool;
  pane : Tmux.pane_id;
  window : Tmux.window_id;
  status : status;
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
[@@deriving yojson_of]

let caller_pane panes self =
  Option.to_result
    (Printf.sprintf "pane %S not found" (Option.map_or ~default:"" string_of_pane_id self))
    (Option.flat_map (Tmux_pane.find panes) self)

let in_session panes states session =
  List.filter
    (fun (_, (s : Subrun.pi)) ->
      Option.exists
        (fun (p : Tmux_pane.t) -> equal_session_id session p.session_id)
        (Option.flat_map (Tmux_pane.find panes) s.pane))
    states

let agents ~dir ~threshold ~self ~caller ~session ~panes =
  let open Result.Infix in
  let+ session =
    match session with
    | Some session -> Ok session
    | None -> (
        match Option.flat_map (Tmux_pane.find panes) self with
        | Some p -> Ok p.session_id
        | None ->
            Error
              (Printf.sprintf "no tmux session for pane %S; pass --session"
                 (Option.map_or ~default:"" string_of_pane_id self)))
  in
  let wake = State.wake ~dir and now = Timestamp.now () and runs = State.runs ~dir panes in
  Pane_map.bindings (State.agents runs)
  |> List.filter_map (fun (pane, (id, (s : Subrun.pi))) ->
      Tmux_pane.find panes pane
      |> Option.filter (fun (p : Tmux_pane.t) -> equal_session_id session p.session_id)
      |> Option.map (fun p -> (id, s, p, (Pane_map.find pane runs).meta)))
  |> List.sort (fun (a, (sa : Subrun.pi), _, _) (b, (sb : Subrun.pi), _, _) ->
      match Float.compare sa.ts sb.ts with 0 -> String.compare a b | c -> c)
  |> List.map (fun (id, (s : Subrun.pi), (p : Tmux_pane.t), (m : Subrun.meta)) ->
      let root = Program_status.root p.program_status in
      {
        id;
        name = State.display_name panes s;
        named = not (String.is_empty s.name);
        pane = p.pane_id;
        window = p.window_id;
        status = Option.map (fun (r : Program_status.record) -> r.state) root;
        activity = s.activity;
        parent = Option.map_or ~default:"" Subrun.string_of_id m.parent;
        depth = Subrun.depth ~dir m;
        self = Option.exists (Subrun.equal_id m.id) caller;
        cwd = p.current_path;
        can_message = not (String.is_empty s.inbox);
        can_reply =
          (not (String.is_empty s.inbox))
          && (List.is_empty m.tools || List.mem ~eq:String.equal "message_agent" m.tools);
        model = s.model;
        since_report = Float.to_int (now -. s.ts);
        stalled = State.stalled_since ~root ~threshold ~wake ~now s;
      })
  |> Tree.order ~id:(fun a -> a.id) ~parent:(fun a -> Some a.parent)

type row =
  | Peer of agent_info
  | Parent of agent_info
  | Own of { run : Runs.info; agent : agent_info option; window : Tmux.window_id option }

let list_runs ~dir ~threshold ~self ~caller ~session ~panes =
  let open Result.Infix in
  let+ agents = agents ~dir ~threshold ~self ~caller ~session ~panes in
  let own = Option.filter (fun _ -> List.exists (fun a -> a.self) agents) caller in
  let parent =
    Option.map_or ~default:"" (fun a -> a.parent) (List.find_opt (fun a -> a.self) agents)
  in
  let visible =
    List.filter_map
      (fun a ->
        if a.self then None
        else if (not (String.is_empty parent)) && String.equal a.id parent then Some (Parent a)
        else if String.equal parent a.parent then
          if String.is_empty parent then Some (Peer a)
          else
            match Subrun.find ~dir a.id with
            | Some ({ kind = Agent; _ } as m) when Option.is_none (Subrun.effective_outcome ~dir m)
              ->
                Some (Peer a)
            | _ -> None
        else None)
      agents
  in
  let ended = ref 0 in
  let runs =
    match own with
    | None -> []
    | Some owner ->
        Runs.list ~owner ~dir ()
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
                  List.find_opt (fun a -> String.equal a.id (Subrun.string_of_id r.meta.id)) agents;
                window =
                  Option.map
                    (fun (p : Tmux_pane.t) -> p.window_id)
                    (Option.flat_map (Tmux_pane.find panes) r.meta.pane);
              })
  in
  visible @ runs

let yojson_of_row row =
  let agent_fields a = match yojson_of_agent_info a with `Assoc fields -> fields | _ -> [] in
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
          | Some a when Option.is_none r.outcome -> agent_fields a
          | _ ->
              [
                ("id", `String (Subrun.string_of_id m.id));
                ("name", `String (Option.map_or ~default:m.name (fun a -> a.name) a));
                ("named", `Bool false);
                ("pane", Tmux_pane.yojson_of_optional_id m.pane);
                ("window", `String (Option.map_or ~default:"" string_of_window_id window));
                ("parent", `String (Option.map_or ~default:"" Subrun.string_of_id m.parent));
                ("cwd", `String m.cwd);
                ("canMessage", `Bool false);
                ("canReply", `Bool false);
              ]
        in
        let extra =
          [
            ("run", `String (Subrun.string_of_id m.id));
            ("state", `String (if Option.is_none r.outcome then "running" else "ended"));
            ("startedAt", Timestamp.yojson_of_t m.started_at);
          ]
          @ Option.map_or ~default:[]
              (fun o -> [ ("outcome", Subrun.yojson_of_outcome o) ])
              r.outcome
        in
        ( fields,
          (match m.kind with Pi | Agent -> "subagent" | Bash | Stream -> "bash"),
          "own",
          extra )
  in
  `Assoc (fields @ [ ("kind", `String kind); ("relationship", `String relationship) ] @ extra)
