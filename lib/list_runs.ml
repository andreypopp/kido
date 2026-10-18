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

type parent = Run.id option

let yojson_of_parent p = `String (match p with Some x -> Run.string_of_id x | None -> "")

type agent_info = {
  id : Run.id;
  name : string;
  named : bool;
  pane : Tmux.pane_id;
  window : Tmux.window_id;
  status : status;
  activity : string;
  parent : parent;
  depth : int;
  self : bool;
  cwd : string;
  can_message : bool; [@key "canMessage"]
  can_reply : bool; [@key "canReply"]
  model : string;
}
[@@deriving yojson_of]

let agents ~dir ~self ~caller ~session ~(state : State.t) =
  let open Result.Infix in
  let+ session =
    match session with
    | Some session -> Ok session
    | None -> (
        match Option.flat_map (State.find state) self with
        | Some p -> Ok p.session_id
        | None ->
            Error
              (Printf.sprintf "no tmux session for pane %S; pass --session"
                 (match self with Some x -> string_of_pane_id x | None -> "")))
  in
  State.live_agents ~dir state
  |> List.filter_map (fun (id, (s : Run.pi)) ->
      let open Option.Infix in
      let* p = Option.bind s.pane (State.find state) in
      let* r = Tmux.Pane_map.find_opt p.pane_id state.runs in
      if not (equal_session_id session p.session_id) then None else Some (id, s, p, r.meta))
  |> List.sort (fun (a, (sa : Run.pi), _, _) (b, (sb : Run.pi), _, _) ->
      match Float.compare sa.ts sb.ts with 0 -> Run.compare_id a b | c -> c)
  |> List.map (fun (id, (s : Run.pi), (p : State.pane), (m : Run.meta)) ->
      let name = Pane_kind.display_name state s in
      {
        id;
        name;
        named = not (String.is_empty s.name);
        pane = p.pane_id;
        window = p.window_id;
        status =
          Option.map
            (fun (r : Program_status.record) -> r.state)
            (Program_status.root p.program_status);
        activity = s.activity;
        parent = Option.flat_map Run.parent_id m.parent;
        depth = Run.depth ~dir m;
        self = Option.exists (Run.equal_id m.id) caller;
        cwd = p.current_path;
        can_message = not (String.is_empty s.inbox);
        can_reply =
          (not (String.is_empty s.inbox))
          && (List.is_empty m.tools || List.mem ~eq:String.equal "message_agent" m.tools);
        model = s.model;
      })
  |> Tree.order ~id:(fun a -> a.id) ~parent:(fun a -> a.parent)

type row =
  | Peer of agent_info
  | Parent of agent_info
  | Own of { run : Run_history.info; agent : agent_info option; window : Tmux.window_id option }

let list_runs ~dir ~self ~caller ~session ~(state : State.t) =
  let open Result.Infix in
  let+ agents = agents ~dir ~self ~caller ~session ~state in
  let own = Option.filter (fun _ -> List.exists (fun a -> a.self) agents) caller in
  let parent = Option.flat_map (fun a -> a.parent) (List.find_opt (fun a -> a.self) agents) in
  let visible =
    List.filter_map
      (fun a ->
        if a.self then None
        else if Option.exists (Run.equal_id a.id) parent then Some (Parent a)
        else if Option.equal Run.equal_id parent a.parent then
          if Option.is_none parent then Some (Peer a)
          else
            match Run.read_meta ~dir a.id with
            | Some ({ kind = Agent; _ } as m) when Option.is_none (State.run_ending ~dir state m) ->
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
        Run_history.list ~parent:(Run.Run owner) ~dir ~state ()
        |> List.filter (fun (r : Run_history.info) ->
            match r.outcome with
            | None -> true
            | Some _ ->
                incr ended;
                !ended <= 20)
        |> List.map (fun (r : Run_history.info) ->
            Own
              {
                run = r;
                agent = List.find_opt (fun a -> Run.equal_id a.id r.meta.id) agents;
                window =
                  (let open Option.Infix in
                   let* pane = r.meta.pane in
                   let+ (p : State.pane) = State.find state pane in
                   p.window_id);
              })
  in
  visible @ runs

let yojson_of_row row =
  let agent_fields a = match yojson_of_agent_info a with `Assoc fields -> fields | _ -> [] in
  let fields, kind, relationship, extra =
    match row with
    | Peer a ->
        (agent_fields a, (if Option.is_none a.parent then "agent" else "subagent"), "peer", [])
    | Parent a ->
        (agent_fields a, (if Option.is_none a.parent then "agent" else "subagent"), "parent", [])
    | Own { run = r; agent = a; window } ->
        let m = r.meta in
        let fields =
          match a with
          | Some a when Option.is_none r.outcome -> agent_fields a
          | _ ->
              [
                ("id", Run.yojson_of_id m.id);
                ("name", `String (match a with Some a -> a.name | None -> m.name));
                ("named", `Bool false);
                ("pane", Run.yojson_of_optional_id m.pane);
                ( "window",
                  `String (match window with Some x -> string_of_window_id x | None -> "") );
                ( "parent",
                  Option.value ~default:(`String "") (Option.map Run.yojson_of_parent m.parent) );
                ("cwd", `String m.cwd);
                ("canMessage", `Bool false);
                ("canReply", `Bool false);
              ]
        in
        let extra =
          [
            ("run", Run.yojson_of_id m.id);
            ("state", `String (if Option.is_none r.outcome then "running" else "ended"));
            ("startedAt", Timestamp.yojson_of_t m.started_at);
          ]
          @ match r.outcome with Some o -> [ ("outcome", Run.yojson_of_outcome o) ] | None -> []
        in
        ( fields,
          (match m.kind with Pi | Agent -> "subagent" | Bash | Stream -> "bash"),
          "own",
          extra )
  in
  `Assoc (fields @ [ ("kind", `String kind); ("relationship", `String relationship) ] @ extra)
