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
  panes : Tmux_pane.t list;
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
    (fun out (p : Tmux_pane.t) ->
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
  match Tmux_pane.list_panes ~conn () with
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
          Option.flat_map
            (fun (c : Tmux.Exec.client_state) -> Tmux_pane.active_pane panes c.session)
            client;
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
  let drawn (p : Tmux_pane.t) =
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
type phase = { running : bool; since : float; drawn : bool; held : Tmux_pane.exit option }

type model = {
  opts : options;
  snap : snapshot;
  sessions : section list;
  pane_data : (Tmux_pane.t * State.pane_kind) Tmux.Pane.Map.t;
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

let ssh_remote m (p : Tmux_pane.t) =
  Option.equal
    (Pair.equal String.equal String.equal)
    (Tmux.Pane.Map.find_opt p.pane_id m.ssh_remote)
    p.ssh
  && Option.is_some p.ssh

(* Strictly after: tmux's timestamps are whole seconds, and an ssh launched in the same second as the
   prompt before it would otherwise pass forever on a host with no integration. The reading latches
   because tmux overwrites pane_command_start_time on the remote shell's own 133;C. *)
let observe_remote m (p : Tmux_pane.t) =
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

let shell_outcome m (p : Tmux_pane.t) =
  match (Tmux_pane.shell p, p.last_exit, p.command_start) with
  | Idle, Some exit, Some _ when Float.(exit.at > 0. && exit.at > seen_at m p.pane_id) -> Some exit
  | _ -> None

let classify m =
  let pane_data =
    List.fold_left
      (fun data (p : Tmux_pane.t) ->
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
        (fun live (p : Tmux_pane.t) -> Tmux.Pane.Map.add p.pane_id () live)
        Tmux.Pane.Map.empty m.snap.panes
    in
    let m =
      List.fold_left
        (fun m (p : Tmux_pane.t) ->
          let m = observe_remote m p in
          match
            if Option.is_some p.ssh && String.equal p.current_command "ssh" && not (ssh_remote m p)
            then Tmux_pane.Running
            else Tmux_pane.shell p
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
      (fun panes (p : Tmux_pane.t) ->
        if Tmux.Pane.Map.mem p.pane_id panes then panes else Tmux.Pane.Map.add p.pane_id p panes)
      Tmux.Pane.Map.empty snap.panes
  in
  let stalled p wake now s =
    let root =
      Option.flat_map (fun (p : Tmux_pane.t) -> Tmux.Program_status.root p.program_status) p
    in
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

let representative ?seen (t : Tmux.Program_status.t) =
  let open Tmux.Program_status in
  let rank = function Blocked _ -> 0 | Error -> 1 | Working _ -> 2 | Done -> 3 | Idle -> 4 in
  List.fold_left
    (fun best r ->
      match r.state with
      | (Done | Error) when Option.exists (fun serial -> serial >= t.serial) seen -> best
      | _ -> (
          match best with
          | Some b
            when let order = Int.compare (rank b.state) (rank r.state) in
                 (if order = 0 then String.compare b.id r.id else order) <= 0 ->
              best
          | _ -> Some r))
    None t.records

let program_status m (p : Tmux_pane.t) =
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
      representative ?seen:(Tmux.Pane.Map.find_opt p.pane_id m.program_seen) status
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

let pane_label m ((p : Tmux_pane.t), (pane_kind : State.pane_kind)) =
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
  let cmd =
    match Tmux_pane.shell p with Running when not p.alternate_on -> p.command_line | _ -> ""
  in
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

type placement = { panes : Tmux_pane.t list; anchor : Tmux.Pane.id option }

let order_windows_by_tree windows states lingering =
  let window_id (w : Tmux_pane.t list) = (List.hd w).window_id in
  let by_session =
    List.fold_left
      (fun acc w ->
        List.fold_left
          (fun acc (p : Tmux_pane.t) ->
            match Tmux.Pane.Map.find_opt p.pane_id states with
            | Some (id, _) when not (String.is_empty id) ->
                String_map.add id (window_id w, p.pane_id) acc
            | _ -> acc)
          acc w)
      String_map.empty windows
  in
  let parent_of_window (w : Tmux_pane.t list) =
    match
      List.find_map
        (fun (p : Tmux_pane.t) ->
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
             (fun (p : Tmux_pane.t) ->
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
    (fun (s : Tmux_pane.session) -> order_windows_by_tree s.windows states lingering)
    (Tmux_pane.order_sessions panes)

let window_target ~next ~session ~window windows =
  let first w = List.hd w.panes in
  let parent w =
    Option.flat_map
      (fun anchor ->
        List.find_opt
          (fun candidate ->
            Tmux.Session.equal (first candidate).session_id (first w).session_id
            && List.exists
                 (fun (p : Tmux_pane.t) -> Tmux.Pane.equal p.pane_id anchor)
                 candidate.panes)
          windows)
      w.anchor
  in
  match
    List.find_opt
      (fun w ->
        Tmux.Session.equal (first w).session_id session
        && Tmux.Window.equal (first w).window_id window)
      windows
  with
  | None -> None
  | Some current -> (
      let rec root w = match parent w with Some p -> root p | None -> w in
      let adjacent =
        Option.flat_map
          (fun p ->
            let siblings =
              List.concat_map
                (fun (pane : Tmux_pane.t) ->
                  List.filter
                    (fun w ->
                      Tmux.Session.equal (first w).session_id session
                      && Option.equal Tmux.Pane.equal w.anchor (Some pane.pane_id))
                    windows)
                p.panes
              |> Array.of_list
            in
            Option.flat_map
              (fun (i, _) ->
                let j = i + if next then 1 else -1 in
                if j >= 0 && j < Array.length siblings then Some (first siblings.(j))
                else if next then None
                else Some (first p))
              (Array.find_idx (fun w -> Tmux.Window.equal (first w).window_id window) siblings))
          (parent current)
      in
      match adjacent with
      | Some _ -> adjacent
      | None ->
          let roots = List.filter (fun w -> Option.is_none (parent w)) windows |> Array.of_list in
          let active = first (root current) in
          let n = Array.length roots in
          let rec find j k =
            if k = 0 then None
            else if List.for_all (fun (p : Tmux_pane.t) -> Option.is_none p.run) roots.(j).panes
            then Some (first roots.(j))
            else find ((j + (if next then 1 else -1) + n) mod n) (k - 1)
          in
          Option.flat_map
            (fun (i, _) -> find ((i + (if next then 1 else -1) + n) mod n) n)
            (Array.find_idx
               (fun w ->
                 Tmux.Session.equal (first w).session_id active.session_id
                 && Tmux.Window.equal (first w).window_id active.window_id)
               roots))

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
      let item (p : Tmux_pane.t) =
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
  let order = Tmux_pane.order_sessions m.snap.panes in
  let sessions =
    List.map
      (fun (s : Tmux_pane.session) ->
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
            (fun (p : Tmux_pane.t) ->
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
    let from, command, missing =
      match target with
      | `Window window ->
          let id = Tmux.Window.to_string window in
          (id, [ "new-window"; "-a"; "-t"; id ], "no such window")
      | `Session session ->
          (Tmux.Session.to_string session ^ ":", [ "new-session" ], "no such session")
    in
    let* cwd =
      Tmux.Exec.exec ?socket [ "display-message"; "-p"; "-t"; from; "#{pane_current_path}" ]
    in
    let* session, window, pane =
      if String.is_empty cwd then Error missing
      else
        let* out =
          Tmux.Exec.exec ?socket
            (command @ [ "-d"; "-P"; "-F"; "#{session_id}:#{window_id}:#{pane_id}"; "-c"; cwd ])
        in
        match String.split ~by:":" out with
        | [ session; window; pane ] -> (
            match
              (Tmux.Session.of_string session, Tmux.Window.of_string window, P.of_string pane)
            with
            | Some session, Some window, Some pane -> Ok (session, window, pane)
            | _ -> Error (Printf.sprintf "created shell but could not read its location: %S" out))
        | _ -> Error (Printf.sprintf "created shell but could not read its location: %S" out)
    in
    Result.map_err
      (fun e ->
        Printf.sprintf "created %s:%s.%s but selection failed: %s" (Tmux.Session.to_string session)
          (Tmux.Window.to_string window) (P.to_string pane) e)
      (jump { session; window; pane })
  in
  match request with
  | Select_window target -> (
      let open Result.Infix in
      let* panes = Tmux_pane.list_panes ?socket () in
      match
        List.find_opt
          (fun (p : Tmux_pane.t) ->
            Tmux.Session.equal p.session_id target.session
            && Tmux.Window.equal p.window_id target.window
            && p.pane_active)
          panes
      with
      | None -> Error "no such window in session"
      | Some p -> jump { session = target.session; window = target.window; pane = p.pane_id })
  | Select_session session -> (
      let open Result.Infix in
      let* panes = Tmux_pane.list_panes ?socket () in
      match
        List.find_opt
          (fun (p : Tmux_pane.t) -> Tmux.Session.equal p.session_id session && p.active)
          panes
      with
      | None -> Error "no such window in session"
      | Some p -> jump { session; window = p.window_id; pane = p.pane_id })
  | New_window window -> create (Some window)
  | New_session -> create None
  | Jump target ->
      let open Result.Infix in
      let* panes = Tmux_pane.list_panes ?socket () in
      if
        List.exists
          (fun (p : Tmux_pane.t) ->
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
      let* panes = Tmux_pane.list_panes ?socket () in
      let candidates = List.filter (fun (p : Tmux_pane.t) -> P.equal p.pane_id pane) panes in
      let target =
        match
          List.find_opt
            (fun (p : Tmux_pane.t) -> Tmux.Session.equal p.session_id current.session_id)
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
             let next = match direction with Next -> true | Prev -> false in
             let windows =
               windows_in_order panes states (lingering_subagents ~dir panes String_map.empty)
             in
             let active =
               Option.flat_map
                 (fun (c : Tmux.Exec.client_state) ->
                   List.find_opt
                     (fun (p : Tmux_pane.t) -> String.equal p.session_name c.session && p.active)
                     (List.concat_map (fun w -> w.panes) windows))
                 (Tmux.Exec.client_state ?socket client)
             in
             match
               Option.flat_map
                 (fun (a : Tmux_pane.t) ->
                   window_target ~next ~session:a.session_id ~window:a.window_id windows)
                 active
             with
             | Some target ->
                 Result.map
                   (fun () -> Some (target.session_id, target.window_id))
                   (Tmux.Exec.run ?socket
                      [
                        "switch-client";
                        "-c";
                        client;
                        "-t";
                        Tmux.Session.to_string target.session_id;
                        ";";
                        "select-window";
                        "-t";
                        Tmux.Window.to_string target.window_id;
                      ])
             | None -> Ok None)
           (Tmux_pane.list_panes ?socket ()))
  | Switch_session direction ->
      switched
        (Result.flat_map
           (fun panes ->
             let sessions = Array.of_list (Tmux_pane.order_sessions panes) in
             let length = Array.length sessions in
             if length < 2 then Ok None
             else
               let current = Tmux.Exec.client_state ?socket client in
               match
                 Array.find_idx
                   (fun (s : Tmux_pane.session) ->
                     Option.exists
                       (fun (c : Tmux.Exec.client_state) -> String.equal c.session s.name)
                       current)
                   sessions
               with
               | Some (i, _) -> (
                   let target =
                     sessions.((i + (match direction with Next -> 1 | Prev -> -1) + length)
                               mod length)
                   in
                   let active =
                     List.find_opt (fun (p : Tmux_pane.t) -> p.active) (List.concat target.windows)
                   in
                   match active with
                   | Some p ->
                       Result.map
                         (fun () -> Some (target.id, p.window_id))
                         (Tmux.Exec.run ?socket
                            [
                              "switch-client"; "-c"; client; "-t"; Tmux.Session.to_string target.id;
                            ])
                   | None -> Ok None)
               | None -> Ok None)
           (Tmux_pane.list_panes ?socket ()))

let%test_module "Tests" =
  (module struct
    let%expect_test "representative priority, tie ordering and visit acknowledgement" =
      let open Tmux.Program_status in
      let get s = parse s |> Result.get_or_failwith in
      let status =
        get
          {|{"serial":8,"records":[{"id":"b","state":"blocked"},{"id":"a","state":"blocked"},{"id":"","state":"error"},{"id":"c","state":"working"},{"id":"d","state":"done"},{"id":"e","state":"idle"}]}|}
      in
      let rec show records =
        match representative { status with records } with
        | None -> ()
        | Some r ->
            print_endline r.id;
            show (List.filter (fun x -> not (String.equal x.id r.id)) records)
      in
      show status.records;
      let siblings =
        {
          status with
          records =
            List.filter (fun r -> List.mem ~eq:String.equal r.id [ ""; "c"; "d" ]) status.records;
        }
      in
      Printf.printf "acknowledged terminal siblings: %s\n"
        (Option.get_exn_or "representative" (representative ~seen:8 siblings)).id;
      Printf.printf "newer terminal siblings: %S\n"
        (Option.get_exn_or "representative" (representative ~seen:7 siblings)).id;
      let completed =
        { status with records = List.filter (fun r -> String.equal r.id "d") status.records }
      in
      Printf.printf "acknowledged only: %b\n" (Option.is_none (representative ~seen:8 completed));
      [%expect
        {|
    a
    b

    c
    d
    e
    acknowledged terminal siblings: c
    newer terminal siblings: ""
    acknowledged only: true
    |}]

    open View_fixture

    let model ?(dir = temp ()) ?(clock = ref test_at) ?(started = test_at -. 3600.) () =
      let m =
        make
          ~now:(fun () -> !clock)
          {
            interval = default_interval;
            client = "";
            socket = None;
            dir;
            threshold = 180.;
            grace = 30.;
          }
      in
      { m with started; at = !clock }

    let placements windows st lingering =
      List.iter
        (fun (pl : placement) ->
          Printf.printf "%s anchor=%s\n"
            (Tmux.Window.to_string (List.hd pl.panes).window_id)
            (Option.map_or ~default:"-" Tmux.Pane.to_string pl.anchor))
        (order_windows_by_tree windows (states st) lingering)

    let w ?run id = [ pane ~window:("@" ^ id) ?run ("%" ^ id) ]

    let ssh_tick clock m p =
      track { m with at = !clock; snap = { empty with client = client "alpha"; panes = [ p ] } }

    let%expect_test "order_windows_by_tree: child after parent, anchored to the parent's pane" =
      placements
        [ w "200"; w "201"; w "203"; w "202" ]
        [
          ("%201", ("root-sess", session ""));
          ("%203", ("", session ~parent:"root-sess" ~depth:1 ""));
          ("%202", ("", session ~parent:"root-sess" ~depth:1 ""));
        ]
        String_map.empty;
      placements
        [ w "200"; w "204" ]
        [ ("%204", ("orphan-sess", session ~parent:"elsewhere-sess" ~depth:1 "")) ]
        String_map.empty;
      placements
        [ w "201"; w "205"; w "206" ]
        [
          ("%201", ("root-sess", session ""));
          ("%205", ("kid-sess", session ~parent:"root-sess" ~depth:1 ""));
          ("%206", ("gk-sess", session ~parent:"kid-sess" ~depth:1 ""));
        ]
        String_map.empty;
      placements
        [ w "207"; w "208" ]
        [
          ("%207", ("a-sess", session ~parent:"b-sess" ""));
          ("%208", ("b-sess", session ~parent:"a-sess" ""));
        ]
        String_map.empty;
      [%expect
        {|
    @200 anchor=-
    @201 anchor=-
    @203 anchor=%201
    @202 anchor=%201
    @200 anchor=-
    @204 anchor=-
    @201 anchor=-
    @205 anchor=%201
    @206 anchor=%205
    @207 anchor=-
    @208 anchor=%207
    |}]

    let%expect_test
        "order_windows_by_tree: the lingering fallback, and a record beating a stale mark" =
      let lingering parent =
        String_map.singleton "run-1"
          { stamp = None; name = ""; parent; outcome = None; kind = Agent; started = test_at }
      in
      placements
        [ w "201"; w ~run:"run-1" "205" ]
        [ ("%201", ("root-sess", session "")) ]
        (lingering "root-sess");
      placements
        [ w "201"; w "209"; w ~run:"run-1" "205" ]
        [
          ("%201", ("root-sess", session ""));
          ("%209", ("other-sess", session ""));
          ("%205", ("kid-sess", session ~parent:"root-sess" ""));
        ]
        (lingering "other-sess");
      placements [ w "200"; w ~run:"run-1" "205" ] [] (lingering "elsewhere-sess");
      placements [ w ~run:"run-1" "205" ] [] (lingering "nonexistent-sess");
      placements
        [ [ pane ~window:"@13" "%21"; pane ~window:"@13" "%101" ]; w "210"; w "211" ]
        [
          ("%21", ("top-sess", session ""));
          ("%101", ("second-sess", session ""));
          ("%210", ("kid1-sess", session ~parent:"top-sess" ~depth:1 ""));
          ("%211", ("kid2-sess", session ~parent:"second-sess" ~depth:1 ""));
        ]
        String_map.empty;
      [%expect
        {|
    @201 anchor=-
    @205 anchor=%201
    @201 anchor=-
    @205 anchor=%201
    @209 anchor=-
    @200 anchor=-
    @205 anchor=-
    @205 anchor=-
    @13 anchor=-
    @210 anchor=%21
    @211 anchor=%101
    |}]

    let%expect_test "window targets: siblings, roots, runs and session occurrences" =
      let pane = Test_fixture.pane in
      let p window id = pane ~window id in
      let root = p "@1" "%1" and later_pane = p "@1" "%2" in
      let child = pane ~window:"@2" ~run:"child" "%3" in
      let sibling = pane ~window:"@3" ~run:"sibling" "%4" in
      let grandchild = pane ~window:"@4" ~run:"grandchild" "%5" in
      let earlier = p "@5" "%6" in
      let other = pane ~session:"b" ~session_id:"$1" ~window:"@6" "%7" in
      let linked = { root with session_name = "b"; session_id = other.session_id } in
      let windows =
        [
          { panes = [ root; later_pane ]; anchor = None };
          { panes = [ child ]; anchor = Some later_pane.pane_id };
          { panes = [ grandchild ]; anchor = Some child.pane_id };
          { panes = [ pane ~window:"@9" ~run:"grand-sibling" "%10" ]; anchor = Some child.pane_id };
          { panes = [ sibling ]; anchor = Some later_pane.pane_id };
          { panes = [ earlier ]; anchor = Some root.pane_id };
          { panes = [ p "@7" "%8" ]; anchor = None };
          { panes = [ pane ~window:"@8" ~run:"orphan" "%9" ]; anchor = None };
          { panes = [ linked ]; anchor = None };
          { panes = [ other ]; anchor = None };
        ]
      in
      List.iter
        (fun (session, window, next) ->
          let target =
            window_target ~next
              ~session:(Option.get_exn_or "session" (Tmux.Session.of_string session))
              ~window:(Option.get_exn_or "window" (Tmux.Window.of_string window))
              windows
          in
          Printf.printf "%s:%s %s -> %s\n" session window
            (if next then "next" else "prev")
            (Option.map_or ~default:"null"
               (fun (p : Tmux_pane.t) ->
                 Tmux.Session.to_string p.session_id ^ ":" ^ Tmux.Window.to_string p.window_id)
               target))
        [
          ("$0", "@1", true);
          ("$0", "@5", true);
          ("$0", "@5", false);
          ("$0", "@2", false);
          ("$0", "@2", true);
          ("$0", "@3", true);
          ("$0", "@4", false);
          ("$0", "@4", true);
          ("$0", "@9", false);
          ("$0", "@9", true);
          ("$0", "@7", true);
          ("$1", "@1", false);
          ("$1", "@6", true);
          ("$0", "@1", false);
        ];
      List.iter
        (fun windows ->
          List.iter
            (fun next ->
              print_endline
                (Option.map_or ~default:"null"
                   (fun (p : Tmux_pane.t) -> Tmux.Window.to_string p.window_id)
                   (window_target ~next ~session:root.session_id ~window:root.window_id windows)))
            [ true; false ])
        [
          [];
          [ { panes = [ root ]; anchor = None } ];
          [ { panes = [ { root with run = Some "only-run" } ]; anchor = None } ];
          [ { panes = [ root; { later_pane with run = Some "split-run" } ]; anchor = None } ];
          [ { panes = [ root ]; anchor = Tmux.Pane.of_string "%999" } ];
        ];
      [%expect
        {|
    $0:@1 next -> $0:@7
    $0:@5 next -> $0:@2
    $0:@5 prev -> $0:@1
    $0:@2 prev -> $0:@5
    $0:@2 next -> $0:@3
    $0:@3 next -> $0:@7
    $0:@4 prev -> $0:@2
    $0:@4 next -> $0:@9
    $0:@9 prev -> $0:@4
    $0:@9 next -> $0:@7
    $0:@7 next -> $1:@1
    $1:@1 prev -> $0:@7
    $1:@6 next -> $0:@1
    $0:@1 prev -> $1:@6
    null
    null
    @1
    @1
    null
    null
    null
    null
    @1
    @1
    |}]

    let%expect_test "window targets: siblings precede parents, next leaves the root subtree" =
      let windows =
        windows_in_order
          (List.concat
             [
               w "201";
               w "209";
               w ~run:"child1" "202";
               w ~run:"child2" "203";
               w ~run:"grandchild" "212";
             ])
          (states
             [
               ("%201", ("root-session", session ""));
               ("%202", ("child1-session", session ~parent:"root-session" ""));
               ("%203", ("child2-session", session ~parent:"root-session" ""));
               ("%212", ("grandchild-session", session ~parent:"child2-session" ""));
             ])
          String_map.empty
      in
      List.iter
        (fun (next, window) ->
          Printf.printf "%s %s -> %s\n"
            (if next then "next" else "prev")
            window
            (Option.map_or ~default:"-"
               (fun (p : Tmux_pane.t) -> Tmux.Window.to_string p.window_id)
               (window_target ~next
                  ~session:(Option.get_exn_or "id" (Tmux.Session.of_string "$0"))
                  ~window:
                    (Option.get_exn_or "id"
                       (Tmux.Window.of_string
                          ("@"
                          ^ List.assoc ~eq:String.equal window
                              [
                                ("other", "209");
                                ("root", "201");
                                ("child2", "203");
                                ("grandchild", "212");
                              ])))
                  windows)))
        [
          (false, "other");
          (false, "root");
          (false, "child2");
          (false, "grandchild");
          (true, "child2");
          (true, "root");
        ];
      [%expect
        {|
    prev other -> @201
    prev root -> @209
    prev child2 -> @202
    prev grandchild -> @203
    next child2 -> @209
    next root -> @209
    |}]

    let%expect_test "lingering entries carry forward; only a missing outcome is re-read" =
      let dir = temp () in
      let id = new_run ~dir "subagent" in
      let panes = [ pane ~window:"@20" ~dead_at:1. ~run:id "%30" ] in
      let first = lingering_subagents ~dir panes String_map.empty in
      let show l =
        let (l : lingering) = String_map.find id l in
        Printf.printf "%s %s\n" l.name
          (Option.map_or ~default:"-" Subrun.string_of_result l.outcome)
      in
      show first;
      Sys.remove (Subrun.meta_path ~dir (Result.get_exn (Subrun.parse_id id)));
      ignore
        (Subrun.record_outcome ~dir
           (Result.get_exn (Subrun.parse_id id))
           { result = Completed; text = ""; at = None });
      show (lingering_subagents ~dir panes first);
      [%expect {|
    subagent -
    subagent completed
    |}]

    let%expect_test "pane_title" =
      let st = states [ ("%1", ("agent", session "%1")) ] in
      List.iter
        (fun title ->
          Printf.printf "%s -> %s\n" title
            (Option.value ~default:"(not an agent)"
               (let p = List.hd (with_programs st [ pane ~title "%1" ]) in
                State.pane_title p (State.pane_kind ~states:st p))))
        [
          "✳ Tmux config";
          "✳ 2 panes";
          "π - kido - kido";
          "π - kido";
          "π - ";
          "plain title";
          "π-no-space";
          "";
          "✳ ";
          "~/src/kido";
        ];
      [%expect
        {|
    ✳ Tmux config -> ✳ Tmux config
    ✳ 2 panes -> ✳ 2 panes
    π - kido - kido -> π - kido - kido
    π - kido -> π - kido
    π -  -> π -
    plain title -> plain title
    π-no-space -> π-no-space
     ->
    ✳  -> ✳
    ~/src/kido -> ~/src/kido
    |}]

    let%expect_test "shell_outcome: the last command's exit since the pane was last looked at" =
      let ended = 1_700_000_100. and visited = 1_700_000_200. in
      let integrated ?(start = 1_700_000_099.) ?exit ?(running = false) () =
        pane ~prompt:ended ~start ~running ?exit "%1"
      in
      let m seen =
        let m = model ~started:test_at () in
        { m with seen }
      in
      let show name m p =
        Printf.printf "%s: %s\n" name
          (Option.map_or ~default:"none"
             (fun (e : Tmux_pane.exit) -> Printf.sprintf "exit %d at %.0f" e.code e.at)
             (shell_outcome m p))
      in
      show "no integration" (m Tmux.Pane.Map.empty) (pane ~exit:(1, ended) "%1");
      show "running" (m Tmux.Pane.Map.empty)
        (integrated ~running:true ~start:(ended +. 1.) ~exit:(1, ended) ());
      show "clean exit, not yet visited" (m Tmux.Pane.Map.empty) (integrated ~exit:(0, ended) ());
      show "nonzero exit, not yet visited" (m Tmux.Pane.Map.empty) (integrated ~exit:(1, ended) ());
      show "nonzero exit, pane visited since"
        (m (Tmux.Pane.Map.singleton (Option.get_exn_or "id" (Tmux.Pane.of_string "%1")) visited))
        (integrated ~exit:(1, ended) ());
      show "no status on record" (m Tmux.Pane.Map.empty) (integrated ());
      show "no command has run" (m Tmux.Pane.Map.empty) (pane ~prompt:ended ~exit:(0, ended) "%1");
      show "no end time" (m Tmux.Pane.Map.empty) (integrated ~exit:(1, 0.) ());
      [%expect
        {|
    no integration: none
    running: none
    clean exit, not yet visited: exit 0 at 1700000100
    nonzero exit, not yet visited: exit 1 at 1700000100
    nonzero exit, pane visited since: none
    no status on record: none
    no command has run: none
    no end time: none
    |}]

    (* Each step says what tmux reports and how much time passed, in milliseconds: tmux's own
   timestamps are whole seconds, and what is tested is kido's observation of the pane. *)
    let%expect_test "shell_indicator debounce on a controlled clock" =
      let cases =
        [
          ( "short command draws nothing",
            true,
            [ (0, false, -1); (50, true, -1); (50, true, -1); (50, false, 0) ] );
          ( "long command draws running, then holds",
            true,
            [
              (0, false, -1);
              (100, true, -1);
              (100, true, -1);
              (100, true, -1);
              (700, true, -1);
              (100, false, 0);
              (400, false, 0);
              (100, false, 0);
            ] );
          ( "clean exit elsewhere replaces the green at once",
            false,
            [ (0, false, -1); (100, true, -1); (300, true, -1); (100, false, 0); (500, false, 0) ]
          );
          ( "failed exit elsewhere replaces the green at once",
            false,
            [ (0, false, -1); (100, true, -1); (300, true, -1); (100, false, 1); (500, false, 1) ]
          );
          ( "a second command inside the hold keeps the green",
            true,
            [
              (0, false, -1);
              (100, true, -1);
              (300, true, -1);
              (100, false, 0);
              (100, true, 0);
              (50, false, 0);
              (500, false, 0);
            ] );
          ( "a command after the hold starts blank again",
            true,
            [
              (0, false, -1);
              (100, true, -1);
              (300, true, -1);
              (100, false, 0);
              (600, false, 0);
              (100, true, 0);
              (200, true, 0);
            ] );
          ( "a new command keeps the outcome until it is drawn",
            false,
            [
              (0, false, -1);
              (100, true, -1);
              (300, true, -1);
              (100, false, 0);
              (600, false, 0);
              (100, true, -1);
              (200, true, -1);
            ] );
        ]
      in
      List.iter
        (fun (name, on_pane, steps) ->
          print_endline name;
          let clock = ref test_at and ms = ref 0 in
          let m = ref (model ~clock ()) in
          List.iter
            (fun (adv, run, stat) ->
              ms := !ms + adv;
              clock := test_at +. (Float.of_int !ms /. 1000.);
              let p =
                pane ~prompt:(test_at -. 1.) ~running:run ~start:test_at
                  ?exit:
                    (if stat >= 0 then Some (stat, Float.of_int (int_of_float !clock)) else None)
                  "%1"
              in
              m :=
                track
                  {
                    !m with
                    at = !clock;
                    snap =
                      {
                        empty with
                        panes = [ p ];
                        active = (if on_pane then Tmux.Pane.of_string "%1" else None);
                      };
                  };
              Printf.printf "  +%dms: %s%s\n" adv
                ((function
                   | None -> "none"
                   | Some (Status Running) -> "running"
                   | Some Done -> "done"
                   | Some Failed -> "failed"
                   | Some _ -> "other")
                   (shell_indicator !m
                      (Tmux.Pane.Map.find
                         (Option.get_exn_or "id" (Tmux.Pane.of_string "%1"))
                         !m.phases)))
                (if shell_pending !m then " pending" else ""))
            steps)
        cases;
      [%expect
        {|
    short command draws nothing
      +0ms: none
      +50ms: none pending
      +50ms: none pending
      +50ms: none
    long command draws running, then holds
      +0ms: none
      +100ms: none pending
      +100ms: none pending
      +100ms: running
      +700ms: running
      +100ms: running pending
      +400ms: running pending
      +100ms: none
    clean exit elsewhere replaces the green at once
      +0ms: none
      +100ms: none pending
      +300ms: running
      +100ms: done pending
      +500ms: done
    failed exit elsewhere replaces the green at once
      +0ms: none
      +100ms: none pending
      +300ms: running
      +100ms: failed pending
      +500ms: failed
    a second command inside the hold keeps the green
      +0ms: none
      +100ms: none pending
      +300ms: running
      +100ms: running pending
      +100ms: running
      +50ms: running pending
      +500ms: none
    a command after the hold starts blank again
      +0ms: none
      +100ms: none pending
      +300ms: running
      +100ms: running pending
      +600ms: none
      +100ms: none pending
      +200ms: running
    a new command keeps the outcome until it is drawn
      +0ms: none
      +100ms: none pending
      +300ms: running
      +100ms: done pending
      +600ms: done
      +100ms: done pending
      +200ms: running
    |}]

    let%expect_test "phases and latches are forgotten with their panes" =
      let m = model ~started:test_at () in
      let m =
        track
          {
            m with
            snap =
              {
                empty with
                active = Tmux.Pane.of_string "%1";
                panes = [ pane ~prompt:test_at ~running:true ~start:test_at "%1" ];
              };
          }
      in
      Printf.printf "phase recorded: %b\n"
        (Tmux.Pane.Map.mem (Option.get_exn_or "id" (Tmux.Pane.of_string "%1")) m.phases);
      let m = track { m with snap = empty } in
      Printf.printf "phases after the pane is gone: %d\n" (Tmux.Pane.Map.cardinal m.phases);
      [%expect {|
    phase recorded: true
    phases after the pane is gone: 0
    |}]

    let%expect_test
        "same ignores a heartbeat's ts and catches any other change; panes compare by exclusion" =
      let snap ts =
        { empty with panes = [ pane "%1" ]; states = states [ ("%1", ("i", session ~ts "")) ] }
      in
      Printf.printf "ts only: %b\n" (same (snap test_at) (snap (test_at +. 60.)));
      Printf.printf "status: %b\n"
        (same (snap test_at)
           { (snap test_at) with panes = with_programs (snap test_at).states (snap test_at).panes });
      let p = pane ~command:"zsh" "%1" in
      Printf.printf "layout: %b\n"
        (same { empty with panes = [ p ] }
           { empty with panes = [ { p with window_layout = "x" } ] });
      Printf.printf "window name: %b\n"
        (same { empty with panes = [ p ] } { empty with panes = [ { p with window_name = "x" } ] });
      Printf.printf "exit: %b\n"
        (same { empty with panes = [ p ] }
           { empty with panes = [ { p with last_exit = Some { code = 1; at = 1. } } ] });
      Printf.printf "command: %b\n"
        (same { empty with panes = [ p ] }
           { empty with panes = [ { p with current_command = "vim" } ] });
      [%expect
        {|
    ts only: true
    status: false
    layout: true
    window name: false
    exit: false
    command: false
    |}]

    let%expect_test
        "the remote latch: same-second prompt, dropped with the session, forgotten with the pane" =
      let clock = ref test_at in
      let m = ref (model ~clock ()) in
      let step d p =
        clock := !clock +. d;
        m := ssh_tick clock !m p;
        not (ssh_remote !m p)
      in
      let start = ssh_pane test_at test_at true (-1) in
      Printf.printf "prompt in the ssh's own second stays running: %b\n"
        (step 0. start && step 0.3 start);
      ignore (step 1. (ssh_pane test_at (test_at +. 1.) true (-1)));
      Printf.printf "the prompt after the first remote command reports: %b\n"
        (not (step 1. (ssh_pane (test_at +. 2.) (test_at +. 1.) false 0)));
      let m2 = ref (model ~clock ()) in
      m2 := ssh_tick clock !m2 (ssh_pane (test_at +. 1.) test_at false (-1));
      Printf.printf "latched: %b\n" (ssh_remote !m2 (ssh_pane 0. 0. false (-1)));
      m2 :=
        track
          {
            !m2 with
            snap =
              {
                empty with
                client = client "alpha";
                panes =
                  [ pane ~session:"alpha" ~command:"zsh" ~pid:4242 ~prompt:(test_at +. 2.) "%1" ];
              };
          };
      Printf.printf "dropped once the pane is a local shell: %b\n"
        (not (ssh_remote !m2 (ssh_pane 0. 0. false (-1))));
      let next = ssh_pane (test_at +. 2.) (test_at +. 3.) true (-1) in
      m2 := ssh_tick clock !m2 next;
      Printf.printf "a second ssh is judged afresh: %b\n" (not (ssh_remote !m2 next));
      m2 := track { !m2 with snap = empty };
      Printf.printf "forgotten with the pane: %b\n" (Tmux.Pane.Map.is_empty !m2.ssh_remote);
      [%expect
        {|
    prompt in the ssh's own second stays running: true
    the prompt after the first remote command reports: true
    latched: true
    dropped once the pane is a local shell: true
    a second ssh is judged afresh: true
    forgotten with the pane: true
    |}]

    let%expect_test "a pause is the wall clock outrunning the monotonic one" =
      let reading wall mono_s : reading =
        { wall; mono = Mtime.of_uint64_ns (Int64.of_float (mono_s *. 1e9)) }
      in
      List.iter
        (fun (name, wall, mono) ->
          Printf.printf "%-26s %b\n" name
            (detect_pause (reading 1000. 1000.) (reading (1000. +. wall) (1000. +. mono))))
        [
          ("awake, tick on schedule", 0.1, 0.1);
          ("awake, tick genuinely slow", 300., 300.);
          ("just under the slack", 4.999, 0.);
          ("just over the slack", 5.001, 0.);
          ("asleep for minutes", 300., 0.05);
        ];
      [%expect
        {|
    awake, tick on schedule    false
    awake, tick genuinely slow false
    just under the slack       false
    just over the slack        true
    asleep for minutes         true
    |}]
  end)
