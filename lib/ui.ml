module P = Tmux.Pane
module String_map = State.String_map
module Style = Mosaic.Ansi.Style
module Color = Mosaic.Ansi.Color

type options = {
  interval : float;
  client : string;
  standalone : bool;
  dir : string;
  threshold : float;
  grace : float;
}

type lingering = { name : string; parent : string; outcome : Subrun.result option }
type probe = { reported : float; read : float; dismissed : bool }

type snapshot = {
  current : string;
  active : string;
  focused : bool;
  panes : P.t list;
  states : (string * State.session) String_map.t;
  ssh : Procs.ssh_session Procs.Int_map.t;
  pi : Procs.Int_set.t;
  probed : float;
  wake : float option;
  err : string option;
  probes : probe String_map.t;
  lingering : lingering String_map.t;
}

let empty =
  {
    current = "";
    active = "";
    focused = false;
    panes = [];
    states = String_map.empty;
    ssh = Procs.Int_map.empty;
    pi = Procs.Int_set.empty;
    probed = 0.;
    wake = None;
    err = None;
    probes = String_map.empty;
    lingering = String_map.empty;
  }

let prompt_grace = 0.5
let probe_interval = 1.
let shell_run_delay = 0.2
let shell_run_hold = 0.5
let procs_probe = 1.

let lingering_subagents ~dir panes states prev =
  let runs = Filename.concat dir "runs" in
  List.fold_left
    (fun out (p : P.t) ->
      match Option.map Subrun.parse_id p.run with
      | Some (Ok run_id)
        when not (String_map.mem p.pane_id states || String_map.mem (Subrun.string_of_id run_id) out)
        -> (
          let key = Subrun.string_of_id run_id in
          let outcome () =
            Option.map (fun (o : Subrun.outcome) -> o.result) (Subrun.read_outcome ~dir:runs run_id)
          in
          match String_map.find_opt key prev with
          | Some l ->
              String_map.add key
                { l with outcome = (if Option.is_some l.outcome then l.outcome else outcome ()) }
                out
          | None -> (
              match Subrun.read_meta ~dir:runs run_id with
              | None -> out
              | Some meta ->
                  String_map.add key
                    { name = meta.name; parent = meta.parent_session; outcome = outcome () }
                    out))
      | _ -> out)
    String_map.empty panes

(* Claude Code only, and Waiting only: the probe stands in for the dismissal gap in the events table
   in hook.ml, which no other agent or status has. *)
let dismissals conn prev states =
  let now = Unix.gettimeofday () in
  String_map.fold
    (fun pane ((_, s) : string * State.session) out ->
      match (s.agent, s.status) with
      | State.Claude, State.Waiting -> (
          match String_map.find_opt pane prev with
          | Some p when Float.(p.reported = s.ts && now - p.read < probe_interval) ->
              String_map.add pane p out
          | _ when Float.(now - s.ts < prompt_grace) -> out
          | _ ->
              let dismissed =
                match Tmux.Conn.capture_pane conn pane with
                | lines -> Screen.at_input_prompt lines
                | exception Failure _ -> false
              in
              String_map.add pane { reported = s.ts; read = now; dismissed } out)
      | _ -> out)
    states String_map.empty

let take ~opts conn prev =
  let current, focused =
    match Tmux.Conn.client_state conn opts.client with
    | Some (c : Tmux.Exec.client_state) -> (c.session, c.focused)
    | None -> ("", false)
  in
  if not (String.is_empty current) then Tmux.Conn.follow conn current;
  match Tmux.Conn.list_panes conn with
  | exception Failure e -> { empty with current; focused; err = Some e }
  | panes ->
      let live = State.load_live ~dir:opts.dir in
      let states = State.by_pane live in
      let scan = ref { Procs.ssh = prev.ssh; pi = prev.pi }
      and read = ref false
      and probed = ref prev.probed in
      let sweep () =
        if (not !read) && Float.(Unix.gettimeofday () - !probed >= procs_probe) then begin
          scan := Procs.sweep ();
          read := true;
          probed := Unix.gettimeofday ()
        end
      in
      let ssh, pi =
        List.fold_left
          (fun (ssh, pi) (p : P.t) ->
            if String.equal p.current_command "ssh" then begin
              if not (Procs.Int_map.mem p.pane_pid !scan.ssh) then sweep ();
              match Procs.Int_map.find_opt p.pane_pid !scan.ssh with
              | Some sess -> (Procs.Int_map.add p.pane_pid sess ssh, pi)
              | None -> (ssh, pi)
            end
            else if Procs.maybe_pi p.current_command && not (String_map.mem p.pane_id states) then begin
              if not (Procs.Int_set.mem p.pane_pid !scan.pi) then sweep ();
              ( ssh,
                if Procs.Int_set.mem p.pane_pid !scan.pi then Procs.Int_set.add p.pane_pid pi
                else pi )
            end
            else (ssh, pi))
          (Procs.Int_map.empty, Procs.Int_set.empty)
          panes
      in
      if not (List.is_empty panes) then
        Reap.collect ~dir:opts.dir ~capture:Subrun.capture_pane ~grace:opts.grace panes live
          ~now:(Unix.gettimeofday ())
          { kill_window = Tmux.Exec.kill_window; kill_pane = Tmux.Exec.kill_pane };
      let probes = dismissals conn prev.probes states in
      let states =
        String_map.fold
          (fun pane p states ->
            if not p.dismissed then states
            else
              String_map.update pane
                (Option.map (fun (id, (s : State.session)) ->
                     (id, { s with status = Idle; ended = Some p.reported })))
                states)
          probes states
      in
      {
        current;
        focused;
        active = Option.value ~default:"" (P.active_pane panes current);
        panes;
        states;
        ssh;
        pi;
        probed = !probed;
        wake = State.wake ~dir:opts.dir;
        err = None;
        probes;
        lingering = lingering_subagents ~dir:opts.dir panes states prev.lingering;
      }

let same a b =
  let drawn (p : P.t) =
    {
      p with
      window_index = 0;
      window_name = "";
      window_layout = "";
      current_path = "";
      active = false;
    }
  in
  let session (_, (s : State.session)) = { s with ts = 0. } in
  String.equal a.current b.current && String.equal a.active b.active
  && Bool.equal a.focused b.focused && Option.is_none a.err && Option.is_none b.err
  && Option.equal Float.equal a.wake b.wake
  && List.equal (fun x y -> Stdlib.( = ) (drawn x) (drawn y)) a.panes b.panes
  && String_map.equal (fun x y -> Stdlib.( = ) (session x) (session y)) a.states b.states
  && Procs.Int_map.equal (fun x y -> Stdlib.( = ) x y) a.ssh b.ssh
  && Procs.Int_set.equal a.pi b.pi
  && String_map.equal (fun x y -> Stdlib.( = ) x y) a.lingering b.lingering

type span = Mosaic.span = { text : string; style : Style.t }
type row = { spans : span list; pane_id : string option }
type phase = { running : bool; since : float; drawn : bool; held : P.exit option }

type model = {
  opts : options;
  conn : Tmux.Conn.t option;
  snap : snapshot;
  rows : row array;
  cursor : int;
  top : int;
  width : int;
  height : int;
  status : string;
  filter : string;
  searching : bool;
  g_pend : bool;
  started : float;
  seen : float String_map.t;
  phases : phase String_map.t;
  ssh_remote : String_map.key list;
  now : unit -> float;
  at : float;
  clock : State.reading;
}

let make ?conn ~now opts =
  let at = now () in
  {
    opts;
    conn;
    snap = empty;
    rows = [||];
    cursor = 0;
    top = 0;
    width = 0;
    height = 0;
    status = "";
    filter = "";
    searching = false;
    g_pend = false;
    started = at;
    seen = String_map.empty;
    phases = String_map.empty;
    ssh_remote = [];
    now;
    at;
    clock = State.read_clock ();
  }

let ssh_interactive m (p : P.t) =
  Option.exists
    (fun (s : Procs.ssh_session) -> s.interactive)
    (Procs.Int_map.find_opt p.pane_pid m.snap.ssh)

let ssh_remote m (p : P.t) = List.mem ~eq:String.equal p.pane_id m.ssh_remote

(* Strictly after: tmux's timestamps are whole seconds, and an ssh launched in the same second as the
   prompt before it would otherwise pass forever on a host with no integration. The reading latches
   because tmux overwrites pane_command_start_time on the remote shell's own 133;C. *)
let observe_remote m (p : P.t) =
  let without = List.filter (fun id -> not (String.equal id p.pane_id)) m.ssh_remote in
  if not (ssh_interactive m p) then { m with ssh_remote = without }
  else
    match (p.last_prompt, p.command_start) with
    | Some prompt, Some start when Float.(prompt > start) && not (ssh_remote m p) ->
        { m with ssh_remote = p.pane_id :: m.ssh_remote }
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

let seen_at m pane = Option.value ~default:m.started (String_map.find_opt pane m.seen)

let shell_outcome m (p : P.t) =
  match (P.shell p, p.last_exit, p.command_start) with
  | Idle, Some exit, Some _ when Float.(exit.at > 0. && exit.at > seen_at m p.pane_id) -> Some exit
  | _ -> None

let track m =
  let m =
    if String.is_empty m.snap.active then m
    else { m with seen = String_map.add m.snap.active m.at m.seen }
  in
  if Option.is_some m.snap.err then m
  else
    let live = List.map (fun (p : P.t) -> p.pane_id) m.snap.panes in
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
              let prev = String_map.find_opt p.pane_id m.phases in
              let ph = observe m prev running in
              let held =
                if running then Option.flat_map (fun p -> p.held) prev else shell_outcome m p
              in
              { m with phases = String_map.add p.pane_id { ph with held } m.phases })
        m m.snap.panes
    in
    let live_pane k = List.mem ~eq:String.equal k live in
    {
      m with
      seen = String_map.filter (fun k _ -> live_pane k) m.seen;
      phases = String_map.filter (fun k _ -> live_pane k) m.phases;
      ssh_remote = List.filter live_pane m.ssh_remote;
    }

let stall_pending m =
  let now = m.now () in
  String_map.exists
    (fun _ (_, (s : State.session)) ->
      (match s.status with Running -> true | _ -> false)
      && not
           (Bool.equal
              (State.stalled_since ~threshold:m.opts.threshold ~wake:m.snap.wake ~now:m.at s)
              (State.stalled_since ~threshold:m.opts.threshold ~wake:m.snap.wake ~now s)))
    m.snap.states

let shell_pending m =
  String_map.exists
    (fun _ ph ->
      (ph.running && not ph.drawn)
      || ((not ph.running) && ph.drawn && Float.(m.at - ph.since < shell_run_hold)))
    m.phases

let done_ m pane =
  match String_map.find_opt pane m.snap.states with
  | Some (_, { status = Idle; ended = Some ended; _ }) -> Float.(ended > seen_at m pane)
  | _ -> false

(* Every style names its foreground: Mosaic's grid paints an explicit white on any cell left
   without one, which would override the user's theme. *)
let st_plain = Style.make ~fg:Color.default ()
let st_current = Style.make ~fg:Color.default ~bold:true ()
let st_proc = Style.make ~fg:Color.white ()
let st_dim = Style.make ~fg:Color.bright_black ()
let st_cursor = Style.make ~fg:Color.default ~inverse:true ()
let st_err = Style.make ~fg:Color.red ()
let st_running = Style.make ~fg:Color.green ()
let st_waiting = Style.make ~fg:Color.yellow ~bold:true ()
let st_compact = Style.make ~fg:Color.magenta ()
let st_done = Style.make ~fg:Color.green ~bold:true ()
let st_unknown = Style.make ~fg:Color.bright_black ()
let st_stalled = Style.make ~fg:Color.red ~bold:true ()
let span style text = { text; style }
let plain text = { text; style = st_plain }

type indicator =
  | Status of State.status
  | Unknown
  | Done
  | Failed
  | Stalled
  | Gone of Subrun.result option

let indicator = function
  | Status Running -> Some (span st_running "◼")
  | Status Waiting -> Some (span st_waiting "◆")
  | Status Compacting -> Some (span st_compact "◌")
  | Status Idle -> None
  | Unknown -> Some (span st_unknown "?")
  | Done -> Some (span st_done "✓")
  | Failed -> Some (span st_err "◼")
  | Stalled -> Some (span st_stalled "!")
  | Gone (Some Completed) -> Some (span st_dim "✓")
  | Gone _ -> Some (span st_dim "×")

let field ind = match ind with None -> [ plain "  " ] | Some i -> [ i; plain " " ]

let shell_indicator m ph =
  match ph with
  | { running = true; drawn = true; _ } -> Some (Status Running)
  | { held = Some exit; _ } -> Some (if exit.code = 0 then Done else Failed)
  | { drawn = true; since; _ } when Float.(m.at - since < shell_run_hold) -> Some (Status Running)
  | _ -> None

let agent_title_of m (p : P.t) =
  if not (State.is_agent_pane m.snap.states ~pi:m.snap.pi p) then None
  else
    match String_map.find_opt p.pane_id m.snap.states with
    | Some (_, { title; _ }) when not (String.is_empty title) -> Some title
    | _ -> ( match State.agent_title p.title with "" -> Some "-" | t -> Some t)

let lingering_label m (p : P.t) =
  match Option.flat_map (fun run -> String_map.find_opt run m.snap.lingering) p.run with
  | None -> None
  | Some l when Option.is_none p.dead_at ->
      Some (field (indicator (Status Running)) @ [ plain l.name ])
  | Some l ->
      Some
        (field (indicator (Gone l.outcome))
        @ [ span st_dim l.name ]
        @ Option.map_or ~default:[]
            (fun o -> [ plain "  "; span st_dim (Subrun.string_of_result o) ])
            l.outcome)

let running_command m (p : P.t) =
  match P.shell p with Running when not (interactive_pane m p) -> p.command_line | _ -> ""

let pane_label m (p : P.t) =
  match agent_title_of m p with
  | None -> (
      match lingering_label m p with
      | Some label -> label
      | None ->
          let cmd = running_command m p in
          let text =
            match Procs.Int_map.find_opt p.pane_pid m.snap.ssh with
            | Some (sess : Procs.ssh_session) ->
                [ span st_proc "ssh "; plain sess.host ]
                @
                if ssh_interactive m p && not (String.is_empty cmd) then
                  [ span st_proc ": "; plain cmd ]
                else []
            | None -> [ span st_proc (if String.is_empty cmd then p.current_command else cmd) ]
          in
          let ind =
            match P.shell p with
            | Unintegrated -> None
            | Idle | Running ->
                if interactive_pane m p then None
                else Option.flat_map (shell_indicator m) (String_map.find_opt p.pane_id m.phases)
          in
          field (Option.flat_map indicator ind) @ text)
  | Some title ->
      let ind, activity =
        match String_map.find_opt p.pane_id m.snap.states with
        | None -> (Unknown, "")
        | Some (_, s) ->
            ( (if State.stalled_since ~threshold:m.opts.threshold ~wake:m.snap.wake ~now:m.at s then
                 Stalled
               else Status s.status),
              s.activity )
      in
      let ind = if done_ m p.pane_id then Done else ind in
      field (indicator ind)
      @ [ plain title ]
      @ if String.is_empty activity then [] else [ plain "  "; span st_dim activity ]

type placement = { panes : P.t list; anchor : string option }

let order_windows_by_tree windows states lingering =
  let window_id (w : P.t list) = (List.hd w).window_id in
  let by_session =
    List.fold_left
      (fun acc w ->
        List.fold_left
          (fun acc (p : P.t) ->
            match String_map.find_opt p.pane_id states with
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
            (String_map.find_opt p.pane_id states))
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
  let parent w =
    Option.map_or ~default:"" fst (String_map.find_opt (parent_of_window w) by_session)
  in
  let ordered = Tree.order ~id:window_id ~parent windows in
  List.fold_left
    (fun (placed, out) w ->
      let anchor =
        if List.mem ~eq:String.equal (parent w) placed then
          Option.map snd (String_map.find_opt (parent_of_window w) by_session)
        else None
      in
      (window_id w :: placed, out @ [ { panes = w; anchor } ]))
    ([], []) ordered
  |> snd

let glyph i n =
  span st_dim (if n = 1 then "╶" else if i = 0 then "┌" else if i = n - 1 then "└" else "├")

let continuation i n = if i < n - 1 then span st_dim "│" else plain " "
let group_glyph i n = span st_dim (if i = n - 1 then "└" else "├")

let append_windows m placements =
  let placements = Array.of_list placements in
  let drawn = Array.make (Array.length placements) false in
  let rows = ref [] in
  let rec emit i prefix lead group_stem =
    if not drawn.(i) then begin
      drawn.(i) <- true;
      let panes = placements.(i).panes in
      let n = List.length panes in
      List.iteri
        (fun j (p : P.t) ->
          let g, nested =
            match lead with
            | None -> ([ glyph j n ], prefix @ [ continuation j n; plain " " ])
            | Some lead when n = 1 -> ([ lead ], prefix @ [ group_stem; plain " " ])
            | Some lead ->
                ( [ (if j > 0 then group_stem else lead); glyph j n ],
                  prefix @ [ group_stem; continuation j n; plain " " ] )
          in
          rows := { spans = prefix @ g @ pane_label m p; pane_id = Some p.pane_id } :: !rows;
          let kids =
            List.filter
              (fun k -> Option.equal String.equal placements.(k).anchor (Some p.pane_id))
              (List.init (Array.length placements) Fun.id)
          in
          let nk = List.length kids in
          List.iteri
            (fun gi k -> emit k nested (Some (group_glyph gi nk)) (continuation gi nk))
            kids)
        panes
    end
  in
  Array.iteri (fun i _ -> emit i [] None (plain "")) placements;
  List.rev !rows

let row_text r = String.concat "" (List.map (fun s -> s.text) r.spans)

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

let index_of m pane =
  Option.map fst
    (CCArray.find_idx (fun r -> Option.equal String.equal r.pane_id (Some pane)) m.rows)

let view_rows m = if m.height > 1 then m.height - 1 else Array.length m.rows
let clamp_top m = { m with top = max 0 (min m.top (Array.length m.rows - view_rows m)) }
let scroll_margin = 3

let ensure_visible m =
  let h = view_rows m in
  let margin = min scroll_margin ((h - 1) / 2) in
  let top =
    if m.cursor - margin < m.top then m.cursor - margin
    else if m.cursor + margin >= m.top + h then m.cursor + margin - h + 1
    else m.top
  in
  clamp_top { m with top }

let move m delta =
  let rec go i =
    if i < 0 || i >= Array.length m.rows then m
    else if Option.is_some m.rows.(i).pane_id then ensure_visible { m with cursor = i }
    else go (i + delta)
  in
  go (m.cursor + delta)

let focus m pane =
  match index_of m pane with Some cursor -> ensure_visible { m with cursor } | None -> m

let rebuild m =
  let prev = Option.flat_map (fun r -> r.pane_id) (CCArray.get_safe m.rows m.cursor) in
  match m.snap.err with
  | Some e -> { m with rows = [| { spans = [ span st_err e ]; pane_id = None } |]; cursor = -1 }
  | None ->
      let order = P.order_sessions m.snap.panes in
      let order =
        if String.is_empty m.filter then order
        else
          List.filter_map
            (fun (s : P.session) ->
              let texts =
                s.name
                :: List.concat_map
                     (List.filter_map (fun (p : P.t) ->
                          match agent_title_of m p with
                          | Some t -> Some t
                          | None ->
                              Option.map
                                (fun (x : Procs.ssh_session) -> x.host)
                                (Procs.Int_map.find_opt p.pane_pid m.snap.ssh)))
                     s.windows
              in
              List.filter_map (fuzzy m.filter) texts
              |> List.reduce max
              |> Option.map (fun score -> (score, s)))
            order
          |> List.stable_sort (fun (a, _) (b, _) -> Int.compare b a)
          |> List.map snd
      in
      let rows =
        List.concat_map
          (fun (s : P.session) ->
            {
              spans =
                [
                  (if String.equal s.name m.snap.current then span st_current s.name
                   else plain s.name);
                ];
              pane_id = None;
            }
            :: append_windows m (order_windows_by_tree s.windows m.snap.states m.snap.lingering))
          order
      in
      let m = { m with rows = Array.of_list rows } in
      let m =
        match Option.flat_map (index_of m) prev with
        | Some cursor -> { m with cursor }
        | None -> move { m with cursor = -1 } 1
      in
      clamp_top m

let next_attention m delta =
  let n = Array.length m.rows in
  let wants i =
    match m.rows.(i).pane_id with
    | None -> false
    | Some pane ->
        (match String_map.find_opt pane m.snap.states with
          | Some (_, { status = Waiting; _ }) -> true
          | _ -> false)
        || done_ m pane
  in
  let rec go k i =
    if k = n then m
    else
      let i = (i + delta + n) mod n in
      if wants i then ensure_visible { m with cursor = i } else go (k + 1) i
  in
  if n = 0 then m else go 0 m.cursor

let set_filter m filter = rebuild { m with filter }
let tmux m f = match f () with () -> m | exception Failure e -> { m with status = e }

let release_focus m =
  match Tmux.Exec.release_side_focus m.opts.client with
  | () -> focus m m.snap.active
  | exception Failure e -> { m with status = e }

type msg =
  | Snapshot of snapshot
  | Key of Mosaic.Event.key
  | Mouse of Mosaic.Event.mouse
  | Resize of int * int

let jump m =
  match Option.flat_map (fun r -> r.pane_id) (CCArray.get_safe m.rows m.cursor) with
  | None -> (m, Mosaic.Cmd.none)
  | Some pane -> (
      match Tmux.Exec.jump ~client:m.opts.client pane with
      | exception Failure e -> ({ m with status = e }, Mosaic.Cmd.none)
      | () ->
          let m =
            if m.searching then focus (set_filter { m with searching = false } "") pane else m
          in
          (m, if m.opts.standalone then Mosaic.Cmd.quit else Mosaic.Cmd.none))

(* C-s reaches the side job whenever it has focus (server-client.c forwards every non-mouse key
   there while CLIENT_SIDESTATUSFOCUS is set), so the toggle back is handled here, not by a second
   tmux binding that would never see it. *)
let key m (k : Mosaic.Event.key) =
  let e = Mosaic.Event.Key.data k in
  let pend = m.g_pend in
  let m = { m with g_pend = false } in
  let none m = (m, Mosaic.Cmd.none) in
  let text =
    match e.key with
    | Char u
      when (not e.modifier.ctrl) && (not e.modifier.alt)
           && Uchar.to_int u >= 0x20
           && Uchar.to_int u <> 0x7f ->
        if String.is_empty e.associated_text then (
          let b = Buffer.create 4 in
          Buffer.add_utf_8_uchar b u;
          Buffer.contents b)
        else e.associated_text
    | _ -> ""
  in
  let ch =
    match e.key with
    | Char u when Uchar.to_int u < 128 -> Some (Char.chr (Uchar.to_int u))
    | _ -> None
  in
  let ctrl c = e.modifier.ctrl && Option.equal Char.equal ch (Some c) in
  let is c = (not e.modifier.ctrl) && (not e.modifier.alt) && Option.equal Char.equal ch (Some c) in
  let top m = move { m with cursor = -1 } 1
  and bottom m = move { m with cursor = Array.length m.rows } (-1) in
  let leave m =
    if m.searching then none (set_filter { m with searching = false } "")
    else if m.opts.standalone then (m, Mosaic.Cmd.quit)
    else none (release_focus m)
  in
  if m.searching && not (String.is_empty text) then none (set_filter m (m.filter ^ text))
  else
    match e.key with
    | Down when e.modifier.shift ->
        none (tmux m (fun () -> Tmux.Exec.switch_window ~client:m.opts.client ~next:true))
    | Up when e.modifier.shift ->
        none (tmux m (fun () -> Tmux.Exec.switch_window ~client:m.opts.client ~next:false))
    | Down | Line_feed -> none (move m 1)
    | Up -> none (move m (-1))
    | _ when ctrl 'j' || ctrl 'n' || is 'j' -> none (move m 1)
    | _ when ctrl 'k' || ctrl 'p' || is 'k' -> none (move m (-1))
    | Enter | KP_enter -> jump m
    | _ when ctrl 's' -> none (if m.opts.standalone then m else release_focus m)
    | Escape -> leave m
    | _ when ctrl 'c' -> leave m
    | _ when is 'q' -> if m.opts.standalone then (m, Mosaic.Cmd.quit) else none m
    | Backspace ->
        if String.is_empty m.filter then none { m with searching = false }
        else
          let rec last i =
            if i > 0 && Char.code m.filter.[i] land 0xc0 = 0x80 then last (i - 1) else i
          in
          none (set_filter m (String.sub m.filter 0 (last (String.length m.filter - 1))))
    | _ when is '/' -> none (set_filter { m with searching = true } "")
    | _ when is 'n' -> none (next_attention m 1)
    | _ when is 'N' -> none (next_attention m (-1))
    | _ when is 'g' && not pend -> none { m with g_pend = true }
    | Home -> none (top m)
    | _ when is 'g' -> none (top m)
    | End -> none (bottom m)
    | _ when is 'G' -> none (bottom m)
    | _ -> none m

let tick ?(wait = true) m =
  match m.conn with
  | None -> Mosaic.Cmd.none
  | Some conn ->
      let opts = m.opts and prev = m.snap in
      Mosaic.Cmd.perform (fun dispatch ->
          if wait then Tmux.Conn.wait conn opts.interval;
          let snap =
            match take ~opts conn prev with
            | snap -> snap
            | exception (Failure e | Sys_error e) -> { empty with err = Some e }
            | exception Unix.Unix_error (e, fn, arg) ->
                { empty with err = Some (Printf.sprintf "%s %s: %s" fn arg (Unix.error_message e)) }
          in
          dispatch (Snapshot snap))

let update msg m =
  match msg with
  | Resize (width, height) -> (ensure_visible { m with width; height }, Mosaic.Cmd.none)
  | Snapshot snap ->
      let was = m.snap in
      let pending = shell_pending m || stall_pending m in
      let clock = State.read_clock () in
      (if State.detect_pause m.clock clock then
         try State.record_pause ~dir:m.opts.dir clock.wall
         with Unix.Unix_error _ | Sys_error _ -> ());
      let m = track { m with at = m.now (); clock; snap } in
      let m = if (not (same snap was)) || pending then rebuild m else m in
      let m =
        if
          ((not (String.equal snap.active was.active)) || (was.focused && not snap.focused))
          && not (String.is_empty snap.active)
        then focus m snap.active
        else m
      in
      (m, tick m)
  | Mouse ev -> (
      match Mosaic.Event.Mouse.kind ev with
      | Down { button = Left } -> (
          let i = m.top + Mosaic.Event.Mouse.y ev in
          match CCArray.get_safe m.rows i with
          | Some { pane_id = Some _; _ } -> jump { m with cursor = i }
          | _ -> (m, Mosaic.Cmd.none))
      | Scroll { direction = Scroll_up; _ } ->
          (clamp_top { m with top = m.top - 3 }, Mosaic.Cmd.none)
      | Scroll { direction = Scroll_down; _ } ->
          (clamp_top { m with top = m.top + 3 }, Mosaic.Cmd.none)
      | _ -> (m, Mosaic.Cmd.none))
  | Key k -> key m k

let measure = Matrix_text.measure ~width_method:`Unicode ~tab_width:2

(* Every row is cut to the width kido was last told, with an ellipsis, before Mosaic lays it out:
   a flex row of texts would shrink its children instead. The bottom line is always reserved, for
   the search prompt or an error, so the frame never changes height. *)
let truncate width spans =
  let rec go room = function
    | [] -> []
    | s :: rest ->
        let w = measure s.text in
        if w <= room then s :: go (room - w) rest
        else
          let cut =
            (Matrix_text.find_wrap_pos ~width_method:`Unicode ~tab_width:2 s.text ~max_columns:room)
              .byte_offset
          in
          [ { s with text = String.sub s.text 0 cut }; plain "…" ]
  in
  if width <= 0 || List.fold_left (fun x s -> x + measure s.text) 0 spans <= width then spans
  else go (width - 1) spans

let view m =
  let h = view_rows m in
  let line spans =
    Mosaic.box ~flex_direction:Row
      ~size:(Mosaic.size_wh (Mosaic.pct 100) (Mosaic.px 1))
      (List.map (fun s -> Mosaic.text ~style:s.style ~selectable:false s.text) spans)
  in
  let row i =
    if i = m.cursor then
      Mosaic.text ~style:st_cursor ~selectable:false
        ~size:(Mosaic.size_wh (Mosaic.pct 100) (Mosaic.px 1))
        (row_text { (m.rows.(i)) with spans = truncate m.width m.rows.(i).spans })
    else line (truncate m.width m.rows.(i).spans)
  in
  let footer =
    if not (String.is_empty m.status) then line (truncate m.width [ span st_err m.status ])
    else if m.searching then line (truncate m.width [ span st_dim "/"; plain m.filter ])
    else line []
  in
  Mosaic.box ~flex_direction:Column
    ~size:(Mosaic.size_wh (Mosaic.pct 100) (Mosaic.pct 100))
    [
      Mosaic.box ~flex_direction:Column ~flex_grow:1. ~flex_shrink:1.
        (List.init (max 0 (min h (Array.length m.rows - m.top))) (fun k -> row (m.top + k)));
      footer;
    ]

let subscriptions _ =
  Mosaic.Sub.batch
    [
      Mosaic.Sub.on_key_all (fun k -> Some (Key k));
      Mosaic.Sub.on_mouse_all (fun ev -> Some (Mouse ev));
      Mosaic.Sub.on_resize (fun ~width ~height -> Resize (width, height));
    ]

let run ~interval ~client =
  let side = Sys.getenv_opt "TMUX_SIDE_CLIENT" in
  let fail msg =
    prerr_endline ("kido: " ^ msg);
    1
  in
  if Option.is_none (Sys.getenv_opt "TMUX") then fail "must run inside tmux"
  else
    let client =
      match (client, side) with
      | Some c, _ when not (String.is_empty c) -> Some c
      | _, Some s when not (String.is_empty s) -> Some s
      | _ ->
          Tmux.Exec.resolve_client
            ~pane:(Option.value ~default:"" (Sys.getenv_opt "TMUX_PANE"))
            ~tmux_env:(Option.value ~default:"" (Sys.getenv_opt "TMUX"))
    in
    match client with
    | None -> fail "no tmux client; pass --client '#{client_name}'"
    | Some client ->
        let opts =
          {
            interval;
            client;
            standalone = Option.map_or ~default:true String.is_empty side;
            dir = State.dir ();
            threshold = State.stall_threshold ();
            grace = Reap.grace ();
          }
        in
        let conn = Tmux.Conn.connect client in
        let init () =
          let m = make ~conn ~now:Unix.gettimeofday opts in
          (m, tick ~wait:false m)
        in
        let matrix =
          Matrix.create ~mode:`Alt ~exit_on_ctrl_c:false ~cursor_visible:false
            ~bracketed_paste:false ~focus_reporting:false ~kitty_keyboard:`Disabled ()
        in
        Fun.protect
          ~finally:(fun () -> Tmux.Conn.close conn)
          (fun () -> Mosaic.run ~matrix { init; update; view; subscriptions });
        0

(* Go's time.Duration syntax, which every caller of --interval already speaks: "100ms", "5s",
   "1m30s". *)
let parse_duration s =
  let units =
    [ ("ns", 1e-9); ("us", 1e-6); ("µs", 1e-6); ("ms", 1e-3); ("s", 1.); ("m", 60.); ("h", 3600.) ]
  in
  let rec go i acc =
    if i >= String.length s then if i = 0 then Error "empty duration" else Ok acc
    else
      let j = ref i in
      while !j < String.length s && (Char.Ascii.is_digit s.[!j] || Char.equal s.[!j] '.') do
        incr j
      done;
      match Float.of_string_opt (String.sub s i (!j - i)) with
      | None -> Error (Printf.sprintf "invalid duration %S" s)
      | Some n -> (
          match List.find_opt (fun (u, _) -> String.prefix ~pre:u (String.drop !j s)) units with
          | None -> Error (Printf.sprintf "missing unit in duration %S" s)
          | Some (u, f) -> go (!j + String.length u) (acc +. (n *. f)))
  in
  go 0 0.
