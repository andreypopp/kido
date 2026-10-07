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
  name : string;
  parent : string;
  outcome : Subrun.result option;
  kind : Subrun.kind;
  started : Timestamp.t;
}

type probe = { reported : float; read : float; dismissed : bool }
type ask_target = Live of Tmux.Pane.id | Revivable | Unavailable
type ask = { ask : Ask.t; target : ask_target }

type snapshot = {
  client : Tmux.Exec.client_state option;
  active : Tmux.Pane.id option;
  panes : P.t list;
  generation : int;
  programs : Tmux.Program_status.t Tmux.Pane.Map.t;
  states : (string * State.session) Tmux.Pane.Map.t;
  ssh : Procs.ssh_session Procs.Int_map.t;
  pi : Procs.Int_set.t;
  probed : float;
  wake : float option;
  err : string option;
  probes : probe Tmux.Pane.Map.t;
  lingering : lingering String_map.t;
  asks : ask list;
}

let empty =
  {
    client = None;
    active = None;
    panes = [];
    generation = -1;
    programs = Tmux.Pane.Map.empty;
    states = Tmux.Pane.Map.empty;
    ssh = Procs.Int_map.empty;
    pi = Procs.Int_set.empty;
    probed = 0.;
    wake = None;
    err = None;
    probes = Tmux.Pane.Map.empty;
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
          | Some l ->
              String_map.add key { l with outcome = Option.or_lazy ~else_:outcome l.outcome } out
          | None -> (
              match Subrun.read_meta ~dir run_id with
              | None -> out
              | Some meta ->
                  String_map.add key
                    {
                      name = meta.name;
                      parent = meta.parent_session;
                      outcome = outcome ();
                      kind = meta.kind;
                      started = meta.started_at;
                    }
                    out))
      | _ -> out)
    String_map.empty panes

let dismissals conn prev states =
  let now = Unix.gettimeofday () in
  Tmux.Pane.Map.fold
    (fun pane ((_, s) : string * State.session) out ->
      match (s.agent, s.status) with
      | State.Claude, State.Waiting -> (
          match Tmux.Pane.Map.find_opt pane prev with
          | Some p when Float.(p.reported = s.ts && now - p.read < 1.) ->
              Tmux.Pane.Map.add pane p out
          | _ when Float.(now - s.ts < 0.5) -> out
          | _ ->
              let dismissed =
                Result.map_or ~default:false Screen.at_input_prompt
                  (Tmux.Conn.capture_pane conn pane)
              in
              Tmux.Pane.Map.add pane { reported = s.ts; read = now; dismissed } out)
      | _ -> out)
    states Tmux.Pane.Map.empty

let take ~opts conn prev client =
  Option.iter (fun (c : Tmux.Exec.client_state) -> Tmux.Conn.follow conn c.session) client;
  match Tmux.Conn.list_panes conn with
  | Error e -> { prev with client; active = None; err = Some e }
  | Ok panes -> (
      let live = State.load_live ~dir:opts.dir in
      let states = State.by_pane live in
      let maybe_pi (p : P.t) =
        Procs.maybe_pi p.current_command && not (Tmux.Pane.Map.mem p.pane_id states)
      in
      let unknown (p : P.t) =
        if String.equal p.current_command "ssh" then not (Procs.Int_map.mem p.pane_pid prev.ssh)
        else maybe_pi p && not (Procs.Int_set.mem p.pane_pid prev.pi)
      in
      let scan, probed =
        if List.exists unknown panes && Float.(Unix.gettimeofday () - prev.probed >= 1.) then
          let scan = Procs.sweep () in
          (scan, Unix.gettimeofday ())
        else ({ Procs.ssh = prev.ssh; pi = prev.pi }, prev.probed)
      in
      let ssh, pi =
        List.fold_left
          (fun (ssh, pi) (p : P.t) ->
            if String.equal p.current_command "ssh" then
              match Procs.Int_map.find_opt p.pane_pid scan.ssh with
              | Some sess -> (Procs.Int_map.add p.pane_pid sess ssh, pi)
              | None -> (ssh, pi)
            else if maybe_pi p && Procs.Int_set.mem p.pane_pid scan.pi then
              (ssh, Procs.Int_set.add p.pane_pid pi)
            else (ssh, pi))
          (Procs.Int_map.empty, Procs.Int_set.empty)
          panes
      in
      if not (List.is_empty panes) then
        Reap.collect ?socket:opts.socket ~dir:opts.dir ~grace:opts.grace panes live
          ~now:(Unix.gettimeofday ());
      let probes = dismissals conn prev.probes states in
      let states =
        Tmux.Pane.Map.fold
          (fun pane p states ->
            if not p.dismissed then states
            else
              Tmux.Pane.Map.update pane
                (Option.map (fun (id, (s : State.session)) ->
                     (id, { s with status = Idle; ended = Some p.reported })))
                states)
          probes states
      in
      let snap =
        {
          prev with
          client;
          active =
            Option.flat_map
              (fun (c : Tmux.Exec.client_state) -> P.active_pane panes c.session)
              client;
          panes;
          states;
          ssh;
          pi;
          probed;
          wake = State.wake ~dir:opts.dir;
          err = None;
          probes;
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
                { ask = a; target })
              (Ask.list ~dir:opts.dir);
        }
      in
      let generation = Tmux.Conn.generation conn in
      match Tmux.Conn.program_status conn ~full:(generation <> prev.generation) with
      | Error e -> { prev with client; active = None; err = Some e }
      | Ok incoming ->
          let previous =
            if generation = prev.generation then prev.programs else Tmux.Pane.Map.empty
          in
          let programs =
            Tmux.Program_status.prune
              ~current:(List.map (fun (p : P.t) -> p.pane_id) panes)
              previous
            |> Tmux.Program_status.merge_panes incoming
          in
          { snap with generation; programs })

let same a b =
  let drawn (p : P.t) =
    { p with window_index = 0; window_layout = ""; current_path = ""; active = false }
  in
  let session (_, (s : State.session)) = { s with ts = 0. } in
  Option.equal Stdlib.( = ) a.client b.client
  && Option.equal P.equal a.active b.active
  && Option.is_none a.err && Option.is_none b.err
  && Option.equal Float.equal a.wake b.wake
  && List.equal (fun x y -> Stdlib.( = ) (drawn x) (drawn y)) a.panes b.panes
  && Tmux.Pane.Map.equal (fun x y -> Stdlib.( = ) (session x) (session y)) a.states b.states
  && a.generation = b.generation
  && Tmux.Pane.Map.equal Stdlib.( = ) a.programs b.programs
  && Procs.Int_map.equal Stdlib.( = ) a.ssh b.ssh
  && Procs.Int_set.equal a.pi b.pi
  && String_map.equal Stdlib.( = ) a.lingering b.lingering
  && List.equal Stdlib.( = ) a.asks b.asks

type reading = { wall : Timestamp.t; mono : Mtime.t }

let read_clock () = { wall = Timestamp.now (); mono = Mtime_clock.now () }

let detect_pause prev now =
  let mono = Mtime.Span.to_float_ns (Mtime.span prev.mono now.mono) /. 1e9 in
  Float.(now.wall - prev.wall - mono > 5.)

type client = { session : Tmux.Session.id; window : Tmux.Window.id; pane : Tmux.Pane.id }

type role =
  [ `Plain | `Current | `Proc | `Dim | `Err | `Running | `Waiting | `Compacting | `Done | `Stalled ]

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
and item = { row : row; children : node list }

type section = { id : Tmux.Session.id; name : string; current : bool; nodes : node list }
type phase = { running : bool; since : float; drawn : bool; held : P.exit option }

type model = {
  opts : options;
  snap : snapshot;
  sessions : section list;
  client : client option;
  started : float;
  seen : float Tmux.Pane.Map.t;
  program_seen : int Tmux.Pane.Map.t;
  phases : phase Tmux.Pane.Map.t;
  ssh_remote : unit Tmux.Pane.Map.t;
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

let ssh_interactive m (p : P.t) =
  Option.exists
    (fun (s : Procs.ssh_session) -> s.interactive)
    (Procs.Int_map.find_opt p.pane_pid m.snap.ssh)

let ssh_remote m (p : P.t) = Tmux.Pane.Map.mem p.pane_id m.ssh_remote

(* Strictly after: tmux's timestamps are whole seconds, and an ssh launched in the same second as the
   prompt before it would otherwise pass forever on a host with no integration. The reading latches
   because tmux overwrites pane_command_start_time on the remote shell's own 133;C. *)
let observe_remote m (p : P.t) =
  if not (ssh_interactive m p) then
    { m with ssh_remote = Tmux.Pane.Map.remove p.pane_id m.ssh_remote }
  else
    match (p.last_prompt, p.command_start) with
    | Some prompt, Some start when Float.(prompt > start) ->
        { m with ssh_remote = Tmux.Pane.Map.add p.pane_id () m.ssh_remote }
    | _ -> m

let interactive_pane m (p : P.t) = (ssh_interactive m p && not (ssh_remote m p)) || p.alternate_on

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

let track m =
  let m =
    match m.snap.active with
    | None -> m
    | Some pane ->
        {
          m with
          seen = Tmux.Pane.Map.add pane m.at m.seen;
          program_seen =
            (match Tmux.Pane.Map.find_opt pane m.snap.programs with
            | None -> m.program_seen
            | Some status -> Tmux.Pane.Map.add pane status.serial m.program_seen);
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
          match P.shell p with
          | Unintegrated -> m
          | (Idle | Running) as s ->
              let running =
                (match s with Running -> true | _ -> false) && not (interactive_pane m p)
              in
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

let stall_pending m =
  let now = m.now () in
  Tmux.Pane.Map.exists
    (fun _ (_, (s : State.session)) ->
      (match s.status with Running -> true | _ -> false)
      && not
           (Bool.equal
              (State.stalled_since ~threshold:m.opts.threshold ~wake:m.snap.wake ~now:m.at s)
              (State.stalled_since ~threshold:m.opts.threshold ~wake:m.snap.wake ~now s)))
    m.snap.states

let shell_pending m =
  Tmux.Pane.Map.exists
    (fun _ ph ->
      (ph.running && not ph.drawn)
      || ((not ph.running) && ph.drawn && Float.(m.at - ph.since < shell_run_hold)))
    m.phases

let done_ m pane =
  match Tmux.Pane.Map.find_opt pane m.snap.states with
  | Some (_, { status = Idle; ended = Some ended; _ }) -> Float.(ended > seen_at m pane)
  | _ -> false

let asking m pane =
  match Tmux.Pane.Map.find_opt pane m.snap.states with
  | None -> false
  | Some (id, _) -> List.exists (fun a -> String.equal a.ask.session id) m.snap.asks

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
    Tmux.Pane.Map.mem p.pane_id m.snap.states
    || Option.exists
         (fun run ->
           Option.exists
             (fun (l : lingering) -> Option.is_some l.outcome || Option.is_some p.dead_at)
             (String_map.find_opt run m.snap.lingering))
         p.run
  then None
  else
    Option.flat_map
      (fun (status : Tmux.Program_status.t) ->
        let record =
          Tmux.Program_status.representative
            ?seen:(Tmux.Pane.Map.find_opt p.pane_id m.program_seen)
            status
          |> Option.or_lazy ~else_:(fun () -> List.head_opt status.records)
        in
        Option.map (fun r -> (status, r)) record)
      (Tmux.Pane.Map.find_opt p.pane_id m.snap.programs)

let attention m pane =
  asking m pane
  || (match Tmux.Pane.Map.find_opt pane m.snap.states with
    | Some (_, { status = Waiting; _ }) -> true
    | _ -> false)
  || done_ m pane
  || Option.exists
       (fun (status, r) ->
         match program_indicator m pane status r with
         | Status Waiting | Done | Failed -> true
         | _ -> false)
       (Option.flat_map (program_status m)
          (List.find_opt (fun (p : P.t) -> P.equal p.pane_id pane) m.snap.panes))

let shell_indicator m ph =
  match ph with
  | { running = true; drawn = true; _ } -> Some (Status Running)
  | { held = Some exit; _ } -> Some (if exit.code = 0 then Done else Failed)
  | { drawn = true; since; _ } when Float.(m.at - since < shell_run_hold) -> Some (Status Running)
  | _ -> None

let agent_title_of m (p : P.t) =
  if not (State.is_agent_pane m.snap.states ~pi:m.snap.pi p) then None
  else
    match Tmux.Pane.Map.find_opt p.pane_id m.snap.states with
    | Some (_, { title; _ }) when not (String.is_empty title) -> Some title
    | _ -> ( match List_runs.agent_title p.title with "" -> Some "-" | t -> Some t)

let span role text = { text; role }
let plain = span `Plain

let pane_label m (p : P.t) =
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
  match (program_status m p, agent_title_of m p) with
  | Some (status, r), agent_title ->
      let app = Tmux.Program_status.app status r in
      let title = Option.value ~default:(Option.value ~default:p.current_command app) r.title in
      let kind =
        match lingering with
        | Some l -> ( match l.kind with Agent -> Agent | Bash | Stream -> Run)
        | None -> if Option.is_some agent_title then Agent else Shell
      in
      row kind
        (Some (program_indicator m p.pane_id status r))
        [ plain title ]
        (Text
           (match
              List.filter
                (fun s -> not (String.is_empty s))
                (Option.to_list r.msg
                @ Option.to_list
                    (Option.map (Printf.sprintf "%d%%") (Tmux.Program_status.progress r)))
            with
           | [] -> []
           | parts -> [ span `Dim (String.concat " " parts) ]))
  | None, None -> (
      match lingering with
      | Some l -> (
          let kind = match l.kind with Agent -> Agent | Bash | Stream -> Run in
          match Option.flat_map (fun (r : run) -> r.started) run with
          | Some started -> row kind (Some (Status Running)) [ plain l.name ] (Elapsed started)
          | None ->
              row kind (Some (Gone l.outcome))
                [ span `Dim l.name ]
                (Text
                   (Option.map_or ~default:[]
                      (fun o -> [ span `Dim (Subrun.string_of_result o) ])
                      l.outcome)))
      | None ->
          let cmd =
            match P.shell p with
            | Running when not (interactive_pane m p) -> p.command_line
            | _ -> ""
          in
          let kind, text =
            match Procs.Int_map.find_opt p.pane_pid m.snap.ssh with
            | Some (sess : Procs.ssh_session) ->
                ( Ssh,
                  [ span `Proc "ssh "; plain sess.host ]
                  @
                  if ssh_interactive m p && not (String.is_empty cmd) then
                    [ span `Proc ": "; plain cmd ]
                  else [] )
            | None ->
                (Shell, [ span `Proc (if String.is_empty cmd then p.current_command else cmd) ])
          in
          let ind =
            if interactive_pane m p then None
            else
              Option.map
                (fun ph -> Option.get_or ~default:(Status Idle) (shell_indicator m ph))
                (Tmux.Pane.Map.find_opt p.pane_id m.phases)
          in
          row kind ind text (Text []))
  | None, Some title ->
      let ind, activity =
        match Tmux.Pane.Map.find_opt p.pane_id m.snap.states with
        | None -> (Unknown, "")
        | Some (_, s) ->
            ( (if State.stalled_since ~threshold:m.opts.threshold ~wake:m.snap.wake ~now:m.at s then
                 Stalled
               else Status s.status),
              s.activity )
      in
      let caption =
        if not (String.is_empty activity) then Text [ span `Dim activity ]
        else
          match run with
          | Some { kind = Agent; started = Some started } -> Elapsed started
          | _ -> Text []
      in
      row Agent
        (Some
           (if asking m p.pane_id then Status Waiting else if done_ m p.pane_id then Done else ind))
        [ plain title ]
        caption

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
        { row = pane_label m p; children = List.filter_map emit kids }
      in
      match placements.(i).panes with
      | [] -> None
      | [ p ] -> Some (Item (item p))
      | p :: rest ->
          let first = item p in
          Some (Group { name = p.window_name; first; rest = List.map item rest })
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
  Option.iter (Tmux.Conn.wait conn) wait;
  let client = Tmux.Conn.client_state conn opts.client in
  let failed e = { prev with client; active = None; err = Some e } in
  match take ~opts conn prev client with
  | snap -> snap
  | exception (Failure e | Sys_error e) -> failed e
  | exception Unix.Unix_error (e, fn, arg) -> failed (Fs.unix_message e fn arg)

let step m (snap : snapshot) =
  let was = m.snap in
  let pending = shell_pending m || stall_pending m in
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
  | New_window : Tmux.Session.id -> (client, string) result request
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
  let create session =
    let open Result.Infix in
    let* cwd_from =
      match session with
      | Some session -> Ok session
      | None -> (
          match Tmux.Exec.client_state ?socket client with
          | Some c -> Ok c.session_id
          | None -> Error "no current tmux session")
    in
    let* panes = Tmux.Exec.list_panes ?socket () in
    match
      List.find_opt (fun (p : P.t) -> Tmux.Session.equal p.session_id cwd_from && p.active) panes
    with
    | None -> Error "no such session"
    | Some p ->
        let* session, window, pane = Tmux.Exec.new_shell ~socket ~session ~cwd:p.current_path in
        Result.map_err
          (fun e ->
            Printf.sprintf "created %s:%s.%s but selection failed: %s"
              (Tmux.Session.to_string session) (Tmux.Window.to_string window) (P.to_string pane) e)
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
            && p.active)
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
  | New_window session -> create (Some session)
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
