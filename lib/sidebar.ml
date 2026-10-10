module P = Tmux.Pane
module String_map = Map.Make (String)

type options = {
  interval : float;
  client : string;
  socket : string option;
  dir : string;
  threshold : float;
  grace : float;
}

let default_interval = 0.1

type lingering = {
  stamp : (int * float) option;
  name : string;
  parent : string;
  outcome : Subrun.result option;
  kind : Subrun.kind;
  started : Timestamp.t;
}

type ask_target = Live of Tmux.Pane.id | Revivable | Unavailable
type ask = { ask : Ask.t; target : ask_target }

type snapshot = {
  client : Tmux.Exec.client_state option;
  active : Tmux.Pane.id option;
  panes : P.t list;
  states : (string * State.session) Tmux.Pane.Map.t;
  wake : float option;
  err : string option;
  lingering : lingering String_map.t;
  asks : ask list;
}

let empty =
  {
    client = None;
    active = None;
    panes = [];
    states = Tmux.Pane.Map.empty;
    wake = None;
    err = None;
    lingering = String_map.empty;
    asks = [];
  }

let shell_run_delay = 0.2
let shell_run_hold = 0.5

let lingering_subagents ~dir panes prev =
  List.fold_left
    (fun out (p : P.t) ->
      match Option.map Subrun.parse_id p.run with
      | Some (Ok run_id) -> (
          let key = Subrun.string_of_id run_id in
          let outcome () =
            Option.map (fun (o : Subrun.outcome) -> o.result) (Subrun.read_outcome ~dir run_id)
          in
          match String_map.find_opt key prev with
          | _ when String_map.mem key out -> out
          | cached -> (
              let stamp =
                try
                  let s = Unix.stat (Subrun.meta_path ~dir run_id) in
                  Some (s.st_ino, s.st_mtime)
                with Unix.Unix_error (ENOENT, _, _) -> None
              in
              let meta =
                if Option.is_none stamp || Option.exists (fun l -> Stdlib.(l.stamp = stamp)) cached
                then None
                else Subrun.read_meta ~dir run_id
              in
              match cached with
              | Some l ->
                  let name = Option.map_or ~default:l.name (fun (m : Subrun.meta) -> m.name) meta in
                  String_map.add key
                    { l with stamp; name; outcome = Option.or_lazy ~else_:outcome l.outcome }
                    out
              | None -> (
                  match meta with
                  | None -> out
                  | Some meta ->
                      String_map.add key
                        {
                          stamp;
                          name = meta.name;
                          parent = meta.parent_session;
                          outcome = outcome ();
                          kind = meta.kind;
                          started = meta.started_at;
                        }
                        out)))
      | _ -> out)
    String_map.empty panes

let take ~opts conn prev client =
  Option.iter (fun (c : Tmux.Exec.client_state) -> Tmux.Conn.follow conn c.session_id) client;
  match Tmux.Conn.list_panes conn with
  | Error e -> { prev with client; active = None; err = Some e }
  | Ok panes ->
      let live = State.load_live ~dir:opts.dir in
      let states = State.by_pane live in
      if not (List.is_empty panes) then
        Reap.collect ?socket:opts.socket ~dir:opts.dir ~grace:opts.grace panes live
          ~now:(Unix.gettimeofday ());
      {
        client;
        active =
          Option.flat_map (fun (c : Tmux.Exec.client_state) -> P.active_pane panes c.session) client;
        panes;
        states;
        wake = State.wake ~dir:opts.dir;
        err = None;
        lingering = lingering_subagents ~dir:opts.dir panes prev.lingering;
        asks =
          List.map
            (fun (a : Ask.t) ->
              let pane =
                Option.flat_map
                  (fun (s : State.session) -> s.pane)
                  (List.assoc_opt ~eq:String.equal a.session live)
              in
              let target =
                match pane with
                | Some pane -> Live pane
                | None -> if Option.is_none (Ask.revival_error a) then Revivable else Unavailable
              in
              let name = Ask.display_name ~panes ~live a in
              { ask = { a with name }; target })
            (Ask.list ~dir:opts.dir);
      }

let same a b =
  let drawn (p : P.t) =
    {
      p with
      window_index = 0;
      window_layout = "";
      current_path = "";
      active = false;
      pane_active = false;
    }
  in
  let session (_, (s : State.session)) = { s with ts = 0. } in
  Option.equal Stdlib.( = ) a.client b.client
  && Option.equal P.equal a.active b.active
  && Option.is_none a.err && Option.is_none b.err
  && Option.equal Float.equal a.wake b.wake
  && List.equal (fun x y -> Stdlib.( = ) (drawn x) (drawn y)) a.panes b.panes
  && Tmux.Pane.Map.equal (fun x y -> Stdlib.( = ) (session x) (session y)) a.states b.states
  && String_map.equal
       (fun x y -> Stdlib.({ x with stamp = None } = { y with stamp = None }))
       a.lingering b.lingering
  && List.equal Stdlib.( = ) a.asks b.asks

type reading = { wall : Timestamp.t; mono : Mtime.t }

let read_clock () = { wall = Timestamp.now (); mono = Mtime_clock.now () }

let detect_pause prev now =
  let mono = Mtime.Span.to_float_ns (Mtime.span prev.mono now.mono) /. 1e9 in
  Float.(now.wall - prev.wall - mono > 5.)

type client = { session : Tmux.Session.id; window : Tmux.Window.id; pane : Tmux.Pane.id }
type role = [ `Plain | `Current | `Proc | `Dim | `Err | `Running | `Waiting | `Done | `Stalled ]
type span = { text : string; role : role }

type indicator =
  | Status of State.status
  | Unknown
  | Done
  | Failed
  | Stalled
  | Gone of Subrun.result option

type caption = Text of span list | Elapsed of float
type row_kind = Agent | Run | Ssh | Shell
type run = { kind : Subrun.kind; started : Timestamp.t option }

type row = {
  pane : Tmux.Pane.id;
  window : Tmux.Window.id;
  kind : row_kind;
  indicator : indicator option;
  title : span list;
  caption : caption;
  run : run option;
}

type node = Group of { name : string; first : item; rest : item list } | Item of item
and item = { row : row; program_rows : program_row list; children : node list }
and program_row = { id : string; indicator : indicator; title : string; caption : string }

type section = { id : Tmux.Session.id; name : string; current : bool; nodes : node list }
type phase = { running : bool; since : float; drawn : bool; held : P.exit option }

type model = {
  opts : options;
  snap : snapshot;
  sessions : section list;
  pane_data : (Tmux.Pane.t * State.pane_kind) Tmux.Pane.Map.t;
  client : client option;
  started : float;
  seen : float Tmux.Pane.Map.t;
  program_seen : int Tmux.Pane.Map.t;
  phases : phase Tmux.Pane.Map.t;
  ssh_remote : (string * string) Tmux.Pane.Map.t;
  now : unit -> float;
  at : float;
  clock : reading;
}

let make ~now opts =
  let at = now () in
  {
    opts;
    snap = empty;
    sessions = [];
    pane_data = Tmux.Pane.Map.empty;
    client = None;
    started = at;
    seen = Tmux.Pane.Map.empty;
    program_seen = Tmux.Pane.Map.empty;
    phases = Tmux.Pane.Map.empty;
    ssh_remote = Tmux.Pane.Map.empty;
    now;
    at;
    clock = read_clock ();
  }

let ssh_remote m (p : P.t) =
  Option.equal
    (Pair.equal String.equal String.equal)
    (Tmux.Pane.Map.find_opt p.pane_id m.ssh_remote)
    p.ssh
  && Option.is_some p.ssh

(* Strictly after: tmux's timestamps are whole seconds, and an ssh launched in the same second as the
   prompt before it would otherwise pass forever on a host with no integration. The reading latches
   because tmux overwrites pane_command_start_time on the remote shell's own 133;C. *)
let observe_remote m (p : P.t) =
  if not (String.equal p.current_command "ssh" && Option.is_some p.ssh) then
    { m with ssh_remote = Tmux.Pane.Map.remove p.pane_id m.ssh_remote }
  else
    let m =
      if ssh_remote m p then m
      else { m with ssh_remote = Tmux.Pane.Map.remove p.pane_id m.ssh_remote }
    in
    match (p.last_prompt, p.command_start, p.ssh) with
    | Some prompt, Some start, Some destination when Float.(prompt > start) ->
        { m with ssh_remote = Tmux.Pane.Map.add p.pane_id destination m.ssh_remote }
    | _ -> m

let observe m prev running =
  match (running, prev) with
  | _, Some prev when Bool.equal running prev.running ->
      if running && (not prev.drawn) && Float.(m.at - prev.since >= shell_run_delay) then
        { prev with drawn = true }
      else prev
  | true, prev ->
      let drawn =
        Option.exists (fun p -> p.drawn && Float.(m.at - p.since < shell_run_hold)) prev
      in
      { running = true; since = m.at; drawn; held = None }
  | false, prev ->
      { running = false; since = m.at; drawn = Option.exists (fun p -> p.drawn) prev; held = None }

let seen_at m pane = Option.value ~default:m.started (Tmux.Pane.Map.find_opt pane m.seen)

let shell_outcome m (p : P.t) =
  match (P.shell p, p.last_exit, p.command_start) with
  | Idle, Some exit, Some _ when Float.(exit.at > 0. && exit.at > seen_at m p.pane_id) -> Some exit
  | _ -> None

let classify m =
  let pane_data =
    List.fold_left
      (fun data (p : P.t) ->
        if Tmux.Pane.Map.mem p.pane_id data then data
        else Tmux.Pane.Map.add p.pane_id (p, State.pane_kind ~states:m.snap.states p) data)
      Tmux.Pane.Map.empty m.snap.panes
  in
  { m with pane_data }

let track m =
  let m = classify m in
  let m =
    match m.snap.active with
    | None -> m
    | Some pane ->
        {
          m with
          seen = Tmux.Pane.Map.add pane m.at m.seen;
          program_seen =
            (match Tmux.Pane.Map.find_opt pane m.pane_data with
            | None -> m.program_seen
            | Some (p, _) -> Tmux.Pane.Map.add pane p.program_status.serial m.program_seen);
        }
  in
  if Option.is_some m.snap.err then m
  else
    let live =
      List.fold_left
        (fun live (p : P.t) -> Tmux.Pane.Map.add p.pane_id () live)
        Tmux.Pane.Map.empty m.snap.panes
    in
    let m =
      List.fold_left
        (fun m (p : P.t) ->
          let m = observe_remote m p in
          match
            if Option.is_some p.ssh && String.equal p.current_command "ssh" && not (ssh_remote m p)
            then P.Running
            else P.shell p
          with
          | Unintegrated -> m
          | (Idle | Running) as s ->
              let running = (match s with Running -> true | _ -> false) && not p.alternate_on in
              let prev = Tmux.Pane.Map.find_opt p.pane_id m.phases in
              let ph = observe m prev running in
              let held =
                if running then Option.flat_map (fun p -> p.held) prev else shell_outcome m p
              in
              { m with phases = Tmux.Pane.Map.add p.pane_id { ph with held } m.phases })
        m m.snap.panes
    in
    let live_pane k _ = Tmux.Pane.Map.mem k live in
    {
      m with
      seen = Tmux.Pane.Map.filter live_pane m.seen;
      program_seen = Tmux.Pane.Map.filter live_pane m.program_seen;
      phases = Tmux.Pane.Map.filter live_pane m.phases;
      ssh_remote = Tmux.Pane.Map.filter live_pane m.ssh_remote;
    }

let stall_pending m snap =
  let panes =
    List.fold_left
      (fun panes (p : P.t) ->
        if Tmux.Pane.Map.mem p.pane_id panes then panes else Tmux.Pane.Map.add p.pane_id p panes)
      Tmux.Pane.Map.empty snap.panes
  in
  let stalled p wake now s =
    let root = Option.flat_map (fun (p : P.t) -> Tmux.Program_status.root p.program_status) p in
    State.stalled_since ~root ~threshold:m.opts.threshold ~wake ~now s
  in
  Tmux.Pane.Map.exists
    (fun pane (_, (s : State.session)) ->
      not
        (Bool.equal
           (Option.exists
              (fun (_, (s : State.session)) ->
                let p =
                  Option.flat_map (fun pane -> Tmux.Pane.Map.find_opt pane m.pane_data) s.pane
                  |> Option.map fst
                in
                stalled p m.snap.wake m.at s)
              (Tmux.Pane.Map.find_opt pane m.snap.states))
           (stalled
              (Option.flat_map (fun pane -> Tmux.Pane.Map.find_opt pane panes) s.pane)
              snap.wake (m.now ()) s)))
    snap.states

let shell_pending m =
  Tmux.Pane.Map.exists
    (fun _ ph ->
      (ph.running && not ph.drawn)
      || ((not ph.running) && ph.drawn && Float.(m.at - ph.since < shell_run_hold)))
    m.phases

let asking m = function
  | State.Terminal | Some_agent _ | Ssh _ -> false
  | Pi_agent { id; _ } -> List.exists (fun a -> String.equal a.ask.session id) m.snap.asks

let program_indicator m pane status (r : Tmux.Program_status.record) =
  let seen =
    Option.exists
      (fun serial -> serial >= status.Tmux.Program_status.serial)
      (Tmux.Pane.Map.find_opt pane m.program_seen)
  in
  match r.state with
  | Idle -> Status Idle
  | Working _ -> Status Running
  | Blocked _ -> Status Waiting
  | Done -> if seen then Status Idle else Done
  | Error -> if seen then Status Idle else Failed

let program_status m (p : P.t) =
  if
    Option.exists
      (fun run ->
        Option.exists
          (fun (l : lingering) -> Option.is_some l.outcome || Option.is_some p.dead_at)
          (String_map.find_opt run m.snap.lingering))
      p.run
  then None
  else
    let status = p.program_status in
    let record =
      Tmux.Program_status.representative
        ?seen:(Tmux.Pane.Map.find_opt p.pane_id m.program_seen)
        status
      |> Option.or_lazy ~else_:(fun () -> List.head_opt status.records)
    in
    Option.map (fun r -> (status, r)) record

let attention m pane =
  Option.exists
    (fun (p, kind) ->
      asking m kind
      || Option.exists
           (fun (status, r) ->
             match program_indicator m pane status r with
             | Status Waiting | Done | Failed -> true
             | _ -> false)
           (program_status m p))
    (Tmux.Pane.Map.find_opt pane m.pane_data)

let shell_indicator m ph =
  match ph with
  | { running = true; drawn = true; _ } -> Some (Status Running)
  | { held = Some exit; _ } -> Some (if exit.code = 0 then Done else Failed)
  | { drawn = true; since; _ } when Float.(m.at - since < shell_run_hold) -> Some (Status Running)
  | _ -> None

let span role text = { text; role }
let plain = span `Plain

let pane_label m ((p : P.t), (pane_kind : State.pane_kind)) =
  let lingering = Option.flat_map (fun run -> String_map.find_opt run m.snap.lingering) p.run in
  let run =
    Option.map
      (fun (l : lingering) ->
        {
          kind = l.kind;
          started =
            (if Option.is_none p.dead_at && Option.is_none l.outcome then Some l.started else None);
        })
      lingering
  in
  let row kind indicator title caption =
    { pane = p.pane_id; window = p.window_id; kind; indicator; title; caption; run }
  in
  let cmd = match P.shell p with Running when not p.alternate_on -> p.command_line | _ -> "" in
  let ssh_title user host =
    [ span `Proc "ssh "; plain (user ^ "@" ^ host) ]
    @ if ssh_remote m p && not (String.is_empty cmd) then [ span `Proc ": "; plain cmd ] else []
  in
  let identity =
    match pane_kind with
    | Pi_agent { id; session } -> Some (id, session)
    | Terminal | Some_agent _ | Ssh _ -> None
  in
  match (lingering, program_status m p) with
  | Some l, _ when Option.is_some l.outcome || Option.is_some p.dead_at ->
      row
        (match l.kind with Agent -> Agent | Bash | Stream -> Run)
        (Some (Gone l.outcome))
        [
          span `Dim
            (Option.map_or ~default:l.name (fun (_, s) -> State.display_name [ p ] s) identity);
        ]
        (Text
           (Option.map_or ~default:[]
              (fun o -> [ span `Dim (Subrun.string_of_result o) ])
              l.outcome))
  | _, Some (status, r) ->
      let root = Tmux.Program_status.root p.program_status in
      let agent_title = State.pane_title p pane_kind in
      let pi =
        match pane_kind with Pi_agent _ -> true | Terminal | Some_agent _ | Ssh _ -> false
      in
      let title =
        match pane_kind with
        | Pi_agent _ | Some_agent _ | Ssh { pane = Remote_agent _; _ } ->
            Option.value ~default:p.current_command agent_title
        | Ssh { user; host; _ } -> "ssh " ^ user ^ "@" ^ host
        | Terminal -> (
            match r.title with
            | Some title -> title
            | None -> Option.value ~default:p.current_command (Tmux.Program_status.app status r))
      in
      let kind =
        match pane_kind with
        | Pi_agent _ | Some_agent _ | Ssh { pane = Remote_agent _; _ } -> Agent
        | Ssh _ -> Ssh
        | Terminal -> ( match lingering with Some { kind = Bash | Stream; _ } -> Run | _ -> Shell)
      in
      let message =
        match
          Option.filter
            (fun message ->
              not (pi && (String.equal title message || String.prefix ~pre:(message ^ " - ") title)))
            r.msg
        with
        | Some message -> message
        | None -> Option.map_or ~default:"" (fun (_, (s : State.session)) -> s.activity) identity
      in
      row kind
        (if
           match pane_kind with
           | Terminal | Ssh { pane = Remote_terminal; _ } -> p.alternate_on
           | Pi_agent _ | Some_agent _ | Ssh _ -> false
         then None
         else
           Some
             (if asking m pane_kind then Status Waiting
              else if
                Option.exists
                  (fun (_, s) ->
                    State.stalled_since ~root ~threshold:m.opts.threshold ~wake:m.snap.wake
                      ~now:m.at s)
                  identity
              then Stalled
              else program_indicator m p.pane_id status r))
        (match pane_kind with
        | Ssh { user; host; pane = Remote_terminal } -> ssh_title user host
        | _ -> [ plain title ])
        (match
           List.filter
             (fun s -> not (String.is_empty s))
             [
               message;
               Option.map_or ~default:"" (Printf.sprintf "%d%%") (Tmux.Program_status.progress r);
             ]
         with
        | [] -> (
            match run with
            | Some { kind = Agent; started = Some started } -> Elapsed started
            | _ -> Text [])
        | parts -> Text [ span `Dim (String.concat " " parts) ])
  | _, None -> (
      match lingering with
      | Some l ->
          let kind = match l.kind with Agent -> Shell | Bash | Stream -> Run in
          row kind (Some (Status Running)) [ plain l.name ] (Elapsed l.started)
      | None ->
          let kind, text =
            match pane_kind with
            | Ssh { user; host; _ } -> (Ssh, ssh_title user host)
            | _ -> (Shell, [ span `Proc (if String.is_empty cmd then p.current_command else cmd) ])
          in
          let ind =
            if p.alternate_on then None
            else
              Option.map
                (fun ph -> Option.get_or ~default:(Status Idle) (shell_indicator m ph))
                (Tmux.Pane.Map.find_opt p.pane_id m.phases)
          in
          row kind ind text (Text []))

type placement = { panes : P.t list; anchor : Tmux.Pane.id option }

let order_windows_by_tree windows states lingering =
  let window_id (w : P.t list) = (List.hd w).window_id in
  let by_session =
    List.fold_left
      (fun acc w ->
        List.fold_left
          (fun acc (p : P.t) ->
            match Tmux.Pane.Map.find_opt p.pane_id states with
            | Some (id, _) when not (String.is_empty id) ->
                String_map.add id (window_id w, p.pane_id) acc
            | _ -> acc)
          acc w)
      String_map.empty windows
  in
  let parent_of_window (w : P.t list) =
    match
      List.find_map
        (fun (p : P.t) ->
          Option.flat_map
            (fun (_, (s : State.session)) ->
              Option.map (fun (pa : State.parent) -> pa.session) s.parent)
            (Tmux.Pane.Map.find_opt p.pane_id states))
        w
    with
    | Some parent -> parent
    | None ->
        Option.value ~default:""
          (List.find_map
             (fun (p : P.t) ->
               Option.map
                 (fun l -> l.parent)
                 (Option.flat_map (fun r -> String_map.find_opt r lingering) p.run))
             w)
  in
  let ordered =
    Tree.order
      ~id:(fun (w, _) -> window_id w)
      ~parent:(fun (_, found) -> Option.map fst found)
      (List.map (fun w -> (w, String_map.find_opt (parent_of_window w) by_session)) windows)
  in
  List.fold_left
    (fun (placed, out) (w, found) ->
      let anchor =
        match found with
        | Some (window, pane) when List.mem ~eq:Tmux.Window.equal window placed -> Some pane
        | _ -> None
      in
      (window_id w :: placed, { panes = w; anchor } :: out))
    ([], []) ordered
  |> snd |> List.rev

let windows_in_order panes states lingering =
  List.concat_map
    (fun (s : P.session) ->
      List.map (fun p -> (p.panes, p.anchor)) (order_windows_by_tree s.windows states lingering))
    (P.order_sessions panes)

let append_windows m placements =
  let placements = Array.of_list placements in
  let drawn = Array.make (Array.length placements) false in
  let anchored =
    Array.foldi
      (fun acc k (pl : placement) ->
        match pl.anchor with
        | None -> acc
        | Some a -> Tmux.Pane.Map.update a (fun l -> Some (k :: Option.get_or ~default:[] l)) acc)
      Tmux.Pane.Map.empty placements
  in
  let rec emit i =
    if drawn.(i) then None
    else begin
      drawn.(i) <- true;
      let item (p : P.t) =
        let kids =
          List.rev (Option.get_or ~default:[] (Tmux.Pane.Map.find_opt p.pane_id anchored))
        in
        Option.map
          (fun data ->
            let programs =
              let status = p.program_status in
              List.filter
                (fun (r : Tmux.Program_status.record) -> not (String.is_empty r.id))
                status.records
              |> List.sort (fun a b ->
                  List.compare String.compare
                    (String.split_on_char '/' a.Tmux.Program_status.id)
                    (String.split_on_char '/' b.id))
              |> List.map (fun (r : Tmux.Program_status.record) ->
                  {
                    id = r.id;
                    indicator = program_indicator m p.pane_id status r;
                    title =
                      Option.filter (fun s -> not (String.is_empty s)) r.title
                      |> Option.value ~default:r.id;
                    caption = Option.value ~default:"" r.msg;
                  })
            in
            {
              row = pane_label m data;
              program_rows = programs;
              children = List.filter_map emit kids;
            })
          (Tmux.Pane.Map.find_opt p.pane_id m.pane_data)
      in
      match placements.(i).panes with
      | [] -> None
      | [ p ] -> Option.map (fun item -> Item item) (item p)
      | p :: rest -> (
          match List.filter_map item (p :: rest) with
          | [] -> None
          | first :: rest -> Some (Group { name = p.window_name; first; rest }))
    end
  in
  Array.foldi
    (fun acc i _ -> match emit i with None -> acc | Some node -> node :: acc)
    [] placements
  |> List.rev

let fuzzy pattern s =
  let n = String.length pattern and s = String.lowercase_ascii s in
  let rec go i j score run =
    if i = n then Some score
    else if j = String.length s then None
    else if Char.equal (Char.lowercase_ascii pattern.[i]) s.[j] then
      go (i + 1) (j + 1) (score + 1 + run) (run + 2)
    else go i (j + 1) (score - 1) 0
  in
  go 0 0 0 0

let filter text sessions =
  if String.is_empty text then sessions
  else
    let rec node = function Item i -> item i | Group g -> List.concat_map item (g.first :: g.rest)
    and item i =
      (match (i.row.kind, i.row.title) with
        | Agent, title -> [ String.concat "" (List.map (fun s -> s.text) title) ]
        | Ssh, _ :: host :: _ -> [ host.text ]
        | _ -> [])
      @ List.concat_map node i.children
    in
    List.filter_map
      (fun (s : section) ->
        List.filter_map (fuzzy text) (s.name :: List.concat_map node s.nodes)
        |> List.reduce max
        |> Option.map (fun score -> (score, s)))
      sessions
    |> List.stable_sort (fun (a, _) (b, _) -> Int.compare b a)
    |> List.map snd

let rebuild m =
  let order = P.order_sessions m.snap.panes in
  let sessions =
    List.map
      (fun (s : P.session) ->
        {
          id = s.id;
          name = s.name;
          current =
            Option.exists
              (fun (c : Tmux.Exec.client_state) -> String.equal s.name c.session)
              m.snap.client;
          nodes = append_windows m (order_windows_by_tree s.windows m.snap.states m.snap.lingering);
        })
      order
  in
  { m with sessions }

let poll ?wait ~(opts : options) conn prev =
  Option.iter (fun timeout -> Tmux.Conn.await_notifications conn ~timeout) wait;
  let client = Tmux.Conn.client_state conn in
  let failed e = { prev with client; active = None; err = Some e } in
  match take ~opts conn prev client with
  | snap -> snap
  | exception (Failure e | Sys_error e) -> failed e
  | exception Unix.Unix_error (e, fn, arg) -> failed (Fs.unix_message e fn arg)

let step m (snap : snapshot) =
  let was = m.snap in
  let pending = shell_pending m || stall_pending m snap in
  let clock = read_clock () in
  (if detect_pause m.clock clock then
     try State.record_pause ~dir:m.opts.dir clock.wall with Unix.Unix_error _ | Sys_error _ -> ());
  let client =
    match snap.client with
    | Some (c : Tmux.Exec.client_state) -> (
        match
          List.find_opt
            (fun (p : P.t) ->
              Option.equal P.equal (Some p.pane_id) snap.active
              && Tmux.Session.equal p.session_id c.session_id)
            snap.panes
        with
        | Some p -> Some { session = p.session_id; window = p.window_id; pane = p.pane_id }
        | None -> m.client)
    | None -> m.client
  in
  let m = track { m with at = m.now (); clock; snap; client } in
  if (not (same snap was)) || pending then (rebuild m, true) else (m, false)

type direction = Next | Prev
type switched = { session : Tmux.Session.id; window : Tmux.Window.id }

type _ request =
  | Switch_window : direction -> (switched option, string) result request
  | Switch_session : direction -> (switched option, string) result request
  | New_window : Tmux.Window.id -> (client, string) result request
  | New_session : (client, string) result request
  | Select_window : switched -> (client, string) result request
  | Select_session : Tmux.Session.id -> (client, string) result request
  | Jump : client -> (client, string) result request
  | Activate_ask : Ask.id -> (client, string) result request
  | Delete_ask : Ask.id -> (unit, string) result request
  | Release_side_focus : (unit, string) result request

let handle : type a. socket:string option -> dir:string -> client:string -> a request -> a =
 fun ~socket ~dir ~client request ->
  let switched result =
    Result.map (Option.map (fun (session, window) -> { session; window })) result
  in
  let jump (target : client) =
    Result.map
      (fun () -> target)
      (Tmux.Exec.jump ?socket ~client ~session:target.session ~window:target.window target.pane)
  in
  let create window =
    let open Result.Infix in
    let* target =
      match window with
      | Some window -> Ok (`Window window)
      | None -> (
          match Tmux.Exec.client_state ?socket client with
          | Some c -> Ok (`Session c.session_id)
          | None -> Error "no current tmux session")
    in
    let* session, window, pane = Tmux.Exec.new_shell ~socket target in
    Result.map_err
      (fun e ->
        Printf.sprintf "created %s:%s.%s but selection failed: %s" (Tmux.Session.to_string session)
          (Tmux.Window.to_string window) (P.to_string pane) e)
      (jump { session; window; pane })
  in
  match request with
  | Select_window target -> (
      let open Result.Infix in
      let* panes = Tmux.Exec.list_panes ?socket () in
      match
        List.find_opt
          (fun (p : P.t) ->
            Tmux.Session.equal p.session_id target.session
            && Tmux.Window.equal p.window_id target.window
            && p.pane_active)
          panes
      with
      | None -> Error "no such window in session"
      | Some p -> jump { session = target.session; window = target.window; pane = p.pane_id })
  | Select_session session -> (
      let open Result.Infix in
      let* panes = Tmux.Exec.list_panes ?socket () in
      match
        List.find_opt (fun (p : P.t) -> Tmux.Session.equal p.session_id session && p.active) panes
      with
      | None -> Error "no such window in session"
      | Some p -> jump { session; window = p.window_id; pane = p.pane_id })
  | New_window window -> create (Some window)
  | New_session -> create None
  | Jump target ->
      let open Result.Infix in
      let* panes = Tmux.Exec.list_panes ?socket () in
      if
        List.exists
          (fun (p : P.t) ->
            Tmux.Session.equal p.session_id target.session
            && Tmux.Window.equal p.window_id target.window
            && P.equal p.pane_id target.pane)
          panes
      then jump target
      else Error "no such pane in session/window"
  | Activate_ask id -> (
      let open Result.Infix in
      let* ask =
        match Ask.read ~dir id with
        | Some ask -> Ok ask
        | None -> Error ("no ask " ^ Ask.string_of_id id)
      in
      let* current =
        match Tmux.Exec.client_state ?socket client with
        | Some c -> Ok c
        | None -> Error "no current tmux session"
      in
      let* pane = Ask.target ~socket ~dir ~session:current.session_id ask in
      let* panes = Tmux.Exec.list_panes ?socket () in
      let candidates = List.filter (fun (p : P.t) -> P.equal p.pane_id pane) panes in
      let target =
        match
          List.find_opt
            (fun (p : P.t) -> Tmux.Session.equal p.session_id current.session_id)
            candidates
        with
        | Some p -> Some p
        | None -> List.head_opt candidates
      in
      match target with
      | None -> Error "asking agent has no pane"
      | Some p -> jump { session = p.session_id; window = p.window_id; pane })
  | Delete_ask id -> Ask.remove ~dir ~self:"" id
  | Release_side_focus -> Tmux.Exec.release_side_focus ?socket client
  | Switch_window direction ->
      switched
        (Result.flat_map
           (fun panes ->
             let states = State.by_pane (State.load_live ~dir) in
             Tmux.Exec.switch_window ?socket ~client
               ~next:(match direction with Next -> true | Prev -> false)
               (windows_in_order panes states (lingering_subagents ~dir panes String_map.empty)))
           (Tmux.Exec.list_panes ?socket ()))
  | Switch_session direction ->
      switched
        (Tmux.Exec.switch_session ~socket ~client
           ~next:(match direction with Next -> true | Prev -> false))
