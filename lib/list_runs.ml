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
  agent : State.agent;
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

let status panes (s : State.session) =
  Option.flat_map (Tmux_pane.find panes) s.pane
  |> Option.flat_map (fun (p : Tmux_pane.t) -> Program_status.root p.program_status)
  |> Option.map (fun (r : Program_status.record) -> r.state)

let per_pane live = List.map snd (Tmux.Pane_map.bindings (State.by_pane live))

let in_session panes states session =
  List.filter
    (fun (_, (s : State.session)) ->
      Option.exists
        (fun (p : Tmux_pane.t) -> equal_session_id session p.session_id)
        (Option.flat_map (Tmux_pane.find panes) s.pane))
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
    match session with
    | Some session -> Ok session
    | None -> (
        match Option.flat_map (Tmux_pane.find panes) self with
        | Some p -> Ok p.session_id
        | None ->
            Error
              (Printf.sprintf
                 "no tmux session for pane %S; pass --session\n\
                  usage: kido tool list_runs [--session ID] [--json]"
                 (Option.map_or ~default:"" string_of_pane_id self)))
  in
  let wake = State.wake ~dir and now = Timestamp.now () in
  let scoped = in_session panes states session in
  let parent e =
    match parent_edge e with
    | Some p when List.mem_assoc ~eq:String.equal p scoped -> Some p
    | _ -> None
  in
  List.sort
    (fun (a, (sa : State.session)) (b, (sb : State.session)) ->
      match Float.compare sa.ts sb.ts with 0 -> String.compare a b | c -> c)
    scoped
  |> Tree.order ~id:fst ~parent
  |> List.filter_map (fun (id, (s : State.session)) ->
      Option.map
        (fun (p : Tmux_pane.t) ->
          let root = Program_status.root p.program_status in
          {
            id;
            name = State.display_name panes s;
            named = State.addressable_name s;
            agent = s.agent;
            pane = p.pane_id;
            window = p.window_id;
            status = Option.map (fun (r : Program_status.record) -> r.state) root;
            activity = s.activity;
            parent = Option.map_or ~default:"" (fun (p : State.parent) -> p.session) s.parent;
            depth = s.depth;
            self = Option.equal equal_pane_id s.pane self;
            cwd = p.current_path;
            can_message = not (String.is_empty s.inbox);
            can_reply = (not (String.is_empty s.inbox)) && can_reply ~dir id;
            model = s.model;
            since_report = Float.to_int (now -. s.ts);
            stalled = State.stalled_since ~root ~threshold ~wake ~now s;
          })
        (Option.flat_map (Tmux_pane.find panes) s.pane))

type row =
  | Peer of agent_info
  | Parent of agent_info
  | Own of { run : Runs.info; agent : agent_info option; window : Tmux.window_id option }

let list_runs ~dir ~threshold ~self ~session =
  let open Result.Infix in
  let* panes = Tmux_pane.list_panes (Tmux.create ()) in
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
            ("startedAt", Timestamp.yojson_of_t m.started_at);
          ]
          @ Option.map_or ~default:[]
              (fun o -> [ ("outcome", Subrun.yojson_of_outcome o) ])
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
         let json = yojson_of_row row in
         let open Yojson.Safe.Util in
         let value json k =
           match member k json with
           | `String s -> s
           | `Int n -> string_of_int n
           | `Bool b -> string_of_bool b
           | _ -> ""
         in
         List.map (value json) columns
         @
         match member "outcome" json with
         | `Null -> [ ""; "" ]
         | o -> List.map (value o) [ "result"; "text" ])
       rows

let%test_module "Tests" =
  (module struct
    open Test_fixture

    let%expect_test "Agent names use the pane title" =
      let panes =
        [
          pane ~title:"π - kido" "%1";
          pane ~title:"π - review - kido" "%2";
          pane ~title:"π - kido" "%3";
        ]
      in
      List.iter
        (fun s -> print_endline (State.display_name panes s))
        [ session ~agent:Pi ~pane:"%1" (); session ~agent:Pi ~pane:"%2" (); session ~pane:"%3" () ];
      [%expect {|
    π - kido
    π - review - kido
    π - kido
    |}]

    let%expect_test "is_ancestor refuses a self-edge" =
      Printf.printf "%b %b\n"
        (is_ancestor [ ("x", "x") ] ~ancestor:"x" "x")
        (is_ancestor [ ("c", "b"); ("b", "a") ] ~ancestor:"a" "c");
      [%expect {| false true |}]
  end)
