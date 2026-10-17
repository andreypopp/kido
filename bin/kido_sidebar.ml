open Kido
module S = Kido.Sidebar
module P = Kido.Pane_status
module Style = Mosaic.Ansi.Style
module Color = Mosaic.Ansi.Color

type span = Mosaic.span = { text : string; style : Style.t }
type program = { state : Tmux.Program_status.state; title : string; caption : string }

type line =
  | Header of { name : string; current : bool }
  | Row of string * Tmux.session_id * S.row
  | Program of string * program
  | Message of string
  | Ask of S.ask

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
  let open S in
  if String.is_empty text then sessions
  else
    let rec node = function Item i -> item i | Group g -> List.concat_map item (g.first :: g.rest)
    and item i =
      (match i.row.lifecycle with
        | Live { status = Some_agent _ | Pi_agent _; _ } | Ended { run = Agent; _ } ->
            [ i.row.title ]
        | Live { status = Ssh { user; host; pane = Remote_agent _ }; _ } ->
            [ i.row.title; user ^ "@" ^ host ]
        | Live { status = Ssh { user; host; _ }; _ } -> [ user ^ "@" ^ host ]
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

let lines ?(search = "") (side : S.model) =
  let glyph i n = if n = 1 then "╶" else if i = 0 then "┌" else if i = n - 1 then "└" else "├" in
  let continuation i n = if i < n - 1 then "│" else " " in
  let out = ref [] in
  let rec node session prefix lead stem = function
    | S.Item item ->
        let g = Option.get_or ~default:"╶" lead in
        let nested = prefix ^ (if Option.is_none lead then " " else stem) ^ " " in
        draw session item (prefix ^ g) nested
    | S.Group group ->
        let panes = group.first :: group.rest in
        let n = List.length panes in
        List.iteri
          (fun j item ->
            let g, nested =
              match lead with
              | None -> (glyph j n, prefix ^ continuation j n ^ " ")
              | Some lead ->
                  ( (if j > 0 then stem else lead) ^ glyph j n,
                    prefix ^ stem ^ continuation j n ^ " " )
            in
            draw session item (prefix ^ g) nested)
          panes
  and draw session (item : S.item) tree nested =
    out := Row (tree, session, item.row) :: !out;
    let rec programs prefix depth trailing = function
      | [] -> ()
      | (n : Tmux.Program_status.node) :: siblings ->
          let r = n.record in
          let nested = prefix ^ String.make (2 * (n.depth - depth)) ' ' in
          let stem = if List.is_empty siblings && not trailing then " " else "│" in
          let branch = if String.equal stem " " then "└" else "├" in
          let title =
            Option.filter (fun s -> not (String.is_empty s)) r.title |> Option.value ~default:r.id
          in
          out :=
            Program
              (nested ^ branch, { state = r.state; title; caption = Option.value ~default:"" r.msg })
            :: !out;
          programs (nested ^ stem ^ " ") (n.depth + 1) false n.children;
          programs prefix depth trailing siblings
    in
    programs nested 1
      (not (List.is_empty item.children))
      (match Tmux.Pane_map.find_opt item.row.pane side.pane_data with
      | None -> []
      | Some { pane = p; _ } -> Tmux.Program_status.forest p.program_status);
    let n = List.length item.children in
    List.iteri
      (fun i child ->
        node session nested (Some (if i = n - 1 then "└" else "├")) (continuation i n) child)
      item.children
  in
  match side.snap.err with
  | Some e -> [| Message e |]
  | None ->
      List.iter
        (fun (s : S.section) ->
          out := Header { name = s.name; current = s.current } :: !out;
          List.iter (node s.id "" None "") s.nodes)
        (filter search side.sessions);
      Array.of_list (List.rev !out)

let span theme role text = { text; style = Sidebar_theme.style theme role }

type mode = Windows | Asks
type source = Agent | Report
type hold = Drawn | Held of float
type view = { report : (source * int) option; exit : (float * float) option; hold : hold option }

type model = {
  side : S.model;
  lines : line array;
  conn : Tmux.Client.t option;
  standalone : bool;
  started : float;
  views : view Tmux.Pane_map.t;
  cursor : int;
  top : int;
  width : int;
  height : int;
  status : string;
  g_pend : bool;
  mode : mode;
  search : string option;
  theme : Sidebar_theme.t;
  theme_error : string option;
  styles_read : (int * float) option;
}

let make ?conn ~standalone (side : S.model) =
  {
    side;
    lines = lines side;
    conn;
    standalone;
    started = side.at;
    views = Tmux.Pane_map.empty;
    cursor = 0;
    top = 0;
    width = 0;
    height = 0;
    status = "";
    g_pend = false;
    mode = Windows;
    search = None;
    theme = Sidebar_theme.default;
    theme_error = None;
    styles_read = None;
  }

let hold = 0.5

let shell (status : S.pane) =
  match status.status with
  | Terminal shell | Ssh { pane = Remote_terminal { status = shell; _ }; _ } -> Some shell
  | Some_agent _ | Pi_agent _ | Ssh { pane = Remote_agent _; _ } -> None

let outcomes (d : S.pane) =
  let outcome source : P.outcome option -> _ = Option.map (fun o -> (source, o)) in
  match (d.status, shell d) with
  | ( ( Some_agent { status = { state = Idle { outcome = o }; _ }; _ }
      | Pi_agent { status = { state = Idle { outcome = o }; _ }; _ }
      | Ssh { pane = Remote_agent { status = { state = Idle { outcome = o }; _ }; _ }; _ } ),
      _ ) ->
      (outcome Agent o, None)
  | _, Some { phase; report } ->
      ( (match report with
        | Some { state = Idle { outcome = o }; _ } -> outcome Report o
        | _ -> None),
        match phase with Idle { last } -> last | Unknown | Running _ | Fullscreen -> None )
  | _ -> (None, None)

let unseen m pane =
  match Tmux.Pane_map.find_opt pane m.side.pane_data with
  | None -> (None, None)
  | Some d ->
      let outcome, exit = outcomes d in
      let view = Tmux.Pane_map.find_opt pane m.views in
      ( Option.filter
          (fun ((source, o) : source * P.outcome) ->
            not
              (Option.exists
                 (fun v -> Option.exists (fun key -> Stdlib.(key = (source, o.serial))) v.report)
                 view))
          outcome,
        Option.filter
          (fun (e : P.exit) ->
            Float.(e.ended_at > m.started)
            && not
                 (Option.exists
                    (fun v ->
                      Option.exists
                        (fun (started_at, ended_at) ->
                          Float.equal started_at e.started_at && Float.equal ended_at e.ended_at)
                        v.exit)
                    view))
          exit )

let observe m =
  if Option.is_some m.side.snap.err then m
  else
    let now = m.side.at and active = S.active m.side.snap in
    let views =
      Tmux.Pane_map.mapi
        (fun pane (d : S.pane) ->
          let prev = Tmux.Pane_map.find_opt pane m.views in
          let raw =
            (match State.shell d.pane with Running -> true | _ -> false)
            && not d.pane.alternate_on
          in
          let hold =
            match (shell d, Option.flat_map (fun v -> v.hold) prev) with
            | Some { phase = Running { fullscreen = false; _ }; _ }, _ -> Some Drawn
            | Some _, Some Drawn -> Some (if raw then Drawn else Held now)
            | Some _, (Some (Held t) as prev) when Float.(now - t < hold) ->
                if raw then Some Drawn else prev
            | _ -> None
          in
          if Option.equal Tmux.equal_pane_id (Some pane) active then
            let outcome, exit = outcomes d in
            {
              report = Option.map (fun (source, (o : P.outcome)) -> (source, o.serial)) outcome;
              exit = Option.map (fun (e : P.exit) -> (e.started_at, e.ended_at)) exit;
              hold;
            }
          else
            match prev with
            | Some v -> { v with hold }
            | None -> { report = None; exit = None; hold })
        m.side.pane_data
    in
    { m with views }

type indicator = Running | Waiting | Done | Failed | Stalled | Ended of Run.result option

let indicator m (r : S.row) =
  let unseen_outcome, unseen_exit = unseen m r.pane in
  let outcome source =
    Option.flat_map
      (fun (s, (o : P.outcome)) ->
        if Stdlib.(s = source) then Some (match o.result with Success -> Done | Failure -> Failed)
        else None)
      unseen_outcome
  in
  let agent (a : P.agent) =
    match a.state with
    | Running _ -> Some Running
    | Waiting _ -> Some Waiting
    | Stalled -> Some Stalled
    | Idle _ -> outcome Agent
  in
  let shell (s : P.shell) =
    match (s.phase, s.report) with
    | (Running { fullscreen = true; _ } | Fullscreen), _ -> None
    | _, Some { state = Running _; _ } -> Some Running
    | _, Some { state = Waiting _; _ } -> Some Waiting
    | _, Some { state = Idle _; _ } -> (
        match (outcome Report, unseen_exit) with
        | (Some Failed as failed), _ -> failed
        | _, Some { code; _ } when code <> 0 -> Some Failed
        | report, _ -> report)
    | phase, None -> (
        let exit =
          Option.map (fun (e : P.exit) -> if e.code = 0 then Done else Failed) unseen_exit
        in
        match
          (phase, Option.flat_map (fun v -> v.hold) (Tmux.Pane_map.find_opt r.pane m.views))
        with
        | Running _, _ | _, Some Drawn -> Some Running
        | _, _ when Option.is_some exit -> exit
        | _, Some (Held t) when Float.(m.side.at - t < hold) -> Some Running
        | Unknown, _
          when match r.lifecycle with Live { run; _ } -> Option.is_some run | Ended _ -> false ->
            Some Running
        | _ -> None)
  in
  match r.lifecycle with
  | Ended { result; _ } -> Some (Ended result)
  | Live { status = Some_agent { status; _ } | Pi_agent { status; _ }; _ }
  | Live { status = Ssh { pane = Remote_agent { status; _ }; _ }; _ } ->
      agent status
  | Live { status = Terminal status; _ }
  | Live { status = Ssh { pane = Remote_terminal { status; _ }; _ }; _ } ->
      shell status

let glyph theme : indicator -> span =
  let span = span theme in
  function
  | Running -> span `Running "◼"
  | Waiting -> span `Waiting "◆"
  | Done -> span `Done "✓"
  | Failed -> span `Err "◼"
  | Stalled -> span `Stalled "!"
  | Ended (Some Completed) -> span `Dim "✓"
  | Ended _ -> span `Dim "×"

let elapsed secs =
  let s = max 0 (Float.to_int secs) in
  if s < 60 then Printf.sprintf "%ds" s
  else if s < 3600 then Printf.sprintf "%dm%02ds" (s / 60) (s mod 60)
  else Printf.sprintf "%dh%02dm" (s / 3600) (s / 60 mod 60)

let command (s : P.shell) =
  match s with
  | { report = None; phase = Running { command; fullscreen = false; _ } }
    when not (String.is_empty command) ->
      Some command
  | _ -> None

let title theme (r : S.row) =
  let span = span theme in
  let plain = span `Plain in
  match r.lifecycle with
  | Ended _ -> [ span `Dim r.title ]
  | Live { status = Ssh { user; host; pane = Remote_terminal { interactive; status } }; _ } -> (
      [ span `Proc "ssh "; plain (user ^ "@" ^ host) ]
      @
      match if interactive then command status else None with
      | Some c -> [ span `Proc ": "; plain c ]
      | None -> [])
  | Live { status = Terminal status; run } -> (
      match command status with
      | Some c -> [ span `Proc c ]
      | None when Option.is_none status.report && Option.is_none run -> [ span `Proc r.title ]
      | None -> [ plain r.title ])
  | Live { status = Some_agent _ | Pi_agent _ | Ssh { pane = Remote_agent _; _ }; _ } ->
      [ plain r.title ]

let caption (r : S.row) =
  let parts msg progress =
    match
      Option.to_list msg @ match progress with Some n -> [ Printf.sprintf "%d%%" n ] | None -> []
    with
    | [] -> None
    | parts -> Some (String.concat " " parts)
  in
  let agent (a : P.agent) =
    parts a.msg
      (match a.state with
      | Running { progress } | Waiting { progress; _ } -> progress
      | Stalled | Idle _ -> None)
  in
  let shell (s : P.shell) =
    Option.flat_map
      (fun (r : P.report) ->
        parts r.msg
          (match r.state with
          | Running { progress } | Waiting { progress; _ } -> progress
          | Idle _ -> None))
      s.report
  in
  match r.lifecycle with
  | Ended { result; _ } -> Option.map Run.string_of_result result
  | Live { status = Some_agent { status; _ } | Pi_agent { status; _ }; _ }
  | Live { status = Ssh { pane = Remote_agent { status; _ }; _ }; _ } ->
      agent status
  | Live { status = Terminal status; _ }
  | Live { status = Ssh { pane = Remote_terminal { status; _ }; _ }; _ } ->
      shell status

let parts m : line -> span list * span list * span list =
  let span = span m.theme in
  let plain = span `Plain in
  function
  | Header h -> ([], [ span (if h.current then `Current else `Session) h.name ], [])
  | Message e -> ([], [ span `Err e ], [])
  | Ask { ask = a; name; target } ->
      let role = match target with Live _ -> `Plain | Revivable | Unavailable -> `Dim in
      ( [],
        [
          span role
            ((if String.is_empty name then String.take 8 (Run.string_of_id a.session) else name)
            ^ " " ^ Ask.string_of_id a.id);
        ],
        [ span role (" " ^ List.hd (String.split_on_char '\n' a.text)) ] )
  | Program (prefix, r) ->
      ( [
          span `Dim prefix;
          (match r.state with
          | Idle -> plain " "
          | Working _ -> glyph m.theme Running
          | Blocked _ -> glyph m.theme Waiting
          | Done -> glyph m.theme Done
          | Error -> glyph m.theme Failed);
        ],
        [ plain r.title ],
        if String.is_empty r.caption then [] else [ plain " "; span `Dim r.caption ] )
  | Row (prefix, _, r) -> (
      let tree = if String.is_empty prefix then [] else [ span `Dim prefix ] in
      ( tree @ [ (match indicator m r with Some x -> glyph m.theme x | None -> plain " ") ],
        title m.theme r,
        match caption r with
        | Some text -> [ plain " "; span `Dim text ]
        | None -> (
            match
              match r.lifecycle with
              | Live { run = Some run; _ } -> Some run.started
              | Live { run = None; _ } | Ended _ -> None
            with
            | Some s -> [ plain " "; span `Dim (elapsed (m.side.at -. s)) ]
            | None -> []) ))

let pane_of : line -> Tmux.pane_id option = function
  | Row (_, _, r) -> Some r.pane
  | Ask { target = Live pane; _ } -> Some pane
  | Ask { target = Revivable | Unavailable; _ } -> None
  | Program _ | Header _ | Message _ -> None

let index_of ~key m pane =
  Option.map fst (CCArray.find_idx (fun l -> Option.equal Stdlib.( = ) (key l) (Some pane)) m.lines)

let view_rows m = if m.height > 1 then m.height - 1 else Array.length m.lines
let shown m = List.init (max 0 (min (view_rows m) (Array.length m.lines - m.top))) (( + ) m.top)
let clamp_top m = { m with top = max 0 (min m.top (Array.length m.lines - view_rows m)) }

let ensure_visible m =
  let h = view_rows m in
  let margin = min 3 ((h - 1) / 2) in
  let top =
    if m.cursor - margin < m.top then m.cursor - margin
    else if m.cursor + margin >= m.top + h then m.cursor + margin - h + 1
    else m.top
  in
  clamp_top { m with top }

let move m delta =
  let rec go i =
    if i < 0 || i >= Array.length m.lines then m
    else if match m.lines.(i) with Row _ | Ask _ -> true | _ -> false then
      ensure_visible { m with cursor = i }
    else go (i + delta)
  in
  go (m.cursor + delta)

let focus m pane =
  match index_of ~key:pane_of m pane with
  | Some cursor -> ensure_visible { m with cursor }
  | None -> m

let redraw m side =
  let key = function
    | Ask { ask = a; _ } -> Some (`Ask a.id)
    | line -> Option.map (fun p -> `Pane p) (pane_of line)
  in
  let prev = Option.flat_map key (CCArray.get_safe m.lines m.cursor) in
  let drawn =
    match m.mode with
    | Windows -> lines ~search:(Option.get_or ~default:"" m.search) side
    | Asks ->
        Array.of_list
          (Header { name = "asks"; current = true } :: List.map (fun a -> Ask a) side.snap.asks)
  in
  let m = { m with side; lines = drawn } in
  match side.snap.err with
  | Some _ -> { m with cursor = -1 }
  | None ->
      let m =
        match Option.flat_map (index_of ~key m) prev with
        | Some cursor -> { m with cursor }
        | None -> move { m with cursor = -1 } 1
      in
      clamp_top m

let set_search m search = redraw { m with search } m.side

let request (opts : S.options) req =
  try S.handle ~tmux:opts.tmux ~dir:opts.dir ~client:opts.client req with
  | Sys_error e -> Error e
  | Unix.Unix_error (e, fn, arg) -> Error (Fs.unix_message e fn arg)

let release_focus m =
  match request m.side.opts S.Release_side_focus with
  | Ok () -> ( match S.active m.side.snap with Some x -> focus m x | None -> m)
  | Error e -> { m with status = e }

type msg =
  | Snapshot of S.snapshot
  | Styles of { read : int * float; reply : string }
  | Key of Mosaic.Event.key
  | Mouse of Mosaic.Event.mouse
  | Resize of int * int

let jump m =
  let req =
    match CCArray.get_safe m.lines m.cursor with
    | Some (Ask { ask = a; _ }) -> Some (S.Activate_ask a.id)
    | Some (Row (_, session, r)) -> Some (S.Jump { session; window = r.window; pane = r.pane })
    | _ -> None
  in
  match req with
  | None -> (m, Mosaic.Cmd.none)
  | Some req -> (
      match request m.side.opts req with
      | Error e -> ({ m with status = e }, Mosaic.Cmd.none)
      | Ok c ->
          let m = if Option.is_some m.search then focus (set_search m None) c.pane else m in
          (m, if m.standalone then Mosaic.Cmd.quit else Mosaic.Cmd.none))

(* C-s reaches the side job whenever it has focus (server-client.c forwards every non-mouse key
   there while CLIENT_SIDESTATUSFOCUS is set), so the toggle back is handled here, not by a second
   tmux binding that would never see it. *)
let key m (k : Mosaic.Event.key) =
  let e = Mosaic.Event.Key.data k in
  let pend = m.g_pend in
  let m = { m with g_pend = false; status = "" } in
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
  and bottom m = move { m with cursor = Array.length m.lines } (-1) in
  let leave m =
    match (m.mode, m.search) with
    | Asks, _ when not m.standalone ->
        none (redraw { m with mode = Windows; cursor = -1; top = 0 } m.side)
    | Asks, _ -> (m, Mosaic.Cmd.quit)
    | Windows, Some _ -> none (set_search m None)
    | Windows, None -> if m.standalone then (m, Mosaic.Cmd.quit) else none (release_focus m)
  in
  let cycle direction =
    match request m.side.opts (S.Switch_window direction) with
    | Ok _ -> m
    | Error e -> { m with status = e }
  in
  match m.search with
  | Some filter when not (String.is_empty text) -> none (set_search m (Some (filter ^ text)))
  | _ -> (
      match e.key with
      | Down when e.modifier.shift -> none (cycle S.Next)
      | Up when e.modifier.shift -> none (cycle S.Prev)
      | Down | Line_feed -> none (move m 1)
      | Up -> none (move m (-1))
      | _ when ctrl 'j' || ctrl 'n' || is 'j' -> none (move m 1)
      | _ when ctrl 'k' || ctrl 'p' || is 'k' -> none (move m (-1))
      | Enter | KP_enter -> jump m
      | _ when ctrl 's' -> none (if m.standalone then m else release_focus m)
      | Escape -> leave m
      | _ when ctrl 'c' -> leave m
      | _ when is 'q' -> if m.standalone then (m, Mosaic.Cmd.quit) else none m
      | Backspace -> (
          match m.search with
          | None -> none m
          | Some "" -> none { m with search = None }
          | Some filter ->
              let rec last i =
                if i > 0 && Char.code filter.[i] land 0xc0 = 0x80 then last (i - 1) else i
              in
              none (set_search m (Some (String.sub filter 0 (last (String.length filter - 1))))))
      | _ when is 'a' && Option.is_none m.search ->
          none
            (redraw
               {
                 m with
                 mode = (match m.mode with Windows -> Asks | Asks -> Windows);
                 cursor = -1;
                 top = 0;
               }
               m.side)
      | _ when is 'd' && match m.mode with Asks -> true | Windows -> false -> (
          match CCArray.get_safe m.lines m.cursor with
          | Some (Ask { ask = a; _ }) -> (
              match request m.side.opts (S.Delete_ask a.id) with
              | Ok () -> none m
              | Error e -> none { m with status = e })
          | _ -> none m)
      | _ when is '/' && match m.mode with Windows -> true | Asks -> false ->
          none (set_search m (Some ""))
      | _ when is 'g' && not pend -> none { m with g_pend = true }
      | Home -> none (top m)
      | _ when is 'g' -> none (top m)
      | End -> none (bottom m)
      | _ when is 'G' -> none (bottom m)
      | _ -> none m)

let next_wait m =
  let now = m.side.now () in
  List.fold_left
    (fun wait i ->
      match m.lines.(i) with
      | Row (_, _, ({ lifecycle = Live { run = Some { started = s; _ }; _ }; _ } as r))
        when Option.is_none (caption r) ->
          Float.min wait (1. -. Float.rem (now -. s) 1.)
      | Row _ | Program _ | Header _ | Message _ | Ask _ -> wait)
    m.side.opts.interval (shown m)

let tick ?wait m =
  match m.conn with
  | None -> Mosaic.Cmd.none
  | Some conn ->
      let opts = m.side.opts and prev = m.side.snap in
      Mosaic.Cmd.perform (fun dispatch ->
          let snap = S.poll ?wait ~opts conn prev in
          let dial = Tmux.Client.dials conn and now = m.side.now () in
          (match m.styles_read with
          | Some (d, at) when Int.equal d dial && Float.(now -. at < 1.) -> ()
          | _ -> (
              match
                Tmux.exec (Tmux.Client.tmux conn) [ "display-message"; "-p"; Sidebar_theme.format ]
              with
              | Ok reply -> dispatch (Styles { read = (dial, now); reply })
              | Error _ -> ()));
          dispatch (Snapshot snap))

let update msg m =
  match msg with
  | Resize (width, height) -> (ensure_visible { m with width; height }, Mosaic.Cmd.none)
  | Styles { read; reply } ->
      let theme, theme_error = Sidebar_theme.load reply in
      ({ m with theme; theme_error; styles_read = Some read }, Mosaic.Cmd.none)
  | Snapshot snap ->
      let was = m.side.snap in
      let m =
        observe
          (match S.step m.side snap with
          | side, true -> redraw m side
          | side, false -> { m with side })
      in
      let m =
        let focused (s : S.snapshot) =
          Option.exists (fun (c : Tmux.client) -> c.focused) s.client
        in
        match S.active snap with
        | Some active
          when (not (Option.equal Tmux.equal_pane_id (Some active) (S.active was)))
               || (focused was && not (focused snap)) -> (
            match m.mode with Windows -> focus m active | Asks -> m)
        | _ -> m
      in
      (m, tick ~wait:(next_wait m) m)
  | Mouse ev -> (
      match Mosaic.Event.Mouse.kind ev with
      | Down { button = Left } -> (
          let i = m.top + Mosaic.Event.Mouse.y ev in
          match CCArray.get_safe m.lines i with
          | Some (Row _ | Ask _) -> jump { m with cursor = i }
          | _ -> (m, Mosaic.Cmd.none))
      | Scroll { direction = Scroll_up; _ } ->
          (clamp_top { m with top = m.top - 3 }, Mosaic.Cmd.none)
      | Scroll { direction = Scroll_down; _ } ->
          (clamp_top { m with top = m.top + 3 }, Mosaic.Cmd.none)
      | _ -> (m, Mosaic.Cmd.none))
  | Key k -> key m k

let measure = Matrix_text.measure ~width_method:`Unicode ~tab_width:2

(* Every row is cut to the width kido was last told, with an ellipsis, before Mosaic lays it out:
   a flex row of texts would shrink its children instead. *)
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
          [ { s with text = String.sub s.text 0 cut }; { s with text = "…" } ]
  in
  if width <= 0 || List.fold_left (fun x s -> x + measure s.text) 0 spans <= width then spans
  else go (width - 1) spans

let view m =
  let span = span m.theme in
  let line ?background spans =
    let spans =
      match background with
      | None -> spans
      | Some bg ->
          List.map
            (fun s ->
              if Option.is_none s.style.bg then { s with style = Style.bg bg s.style } else s)
            spans
    in
    Mosaic.box ~flex_direction:Row ?background
      ~size:(Mosaic.size_wh (Mosaic.pct 100) (Mosaic.px 1))
      (List.map (fun s -> Mosaic.text ~style:s.style ~selectable:false s.text) spans)
  in
  let row (i, tint) =
    let l = m.lines.(i) in
    let lead, title, tail = parts m l in
    let background =
      match l with
      | Header h -> (Sidebar_theme.style m.theme (if h.current then `Current else `Session)).bg
      | Row _ | Program _ | Ask _ | Message _ -> tint
    in
    let title =
      if i = m.cursor then
        List.map (fun s -> { s with style = Style.with_inverse true s.style }) title
      else title
    in
    line ?background (truncate m.width (lead @ title @ tail))
  in
  let rows =
    match Sidebar_theme.current_rows m.theme with
    | None -> List.map (fun i -> (i, None)) (shown m)
    | Some bg ->
        let session i =
          match m.lines.(i) with
          | Header h -> Some h.current
          | Message _ -> Some false
          | Row _ | Program _ | Ask _ -> None
        in
        let rec above i =
          if i < 0 then false else Option.get_lazy (fun () -> above (i - 1)) (session i)
        in
        snd
          (List.fold_map
             (fun current i ->
               let current = Option.get_or ~default:current (session i) in
               (current, (i, if current then Some bg else None)))
             (above (m.top - 1))
             (shown m))
  in
  let footer =
    if not (String.is_empty m.status) then line (truncate m.width [ span `Err m.status ])
    else
      match (m.search, m.theme_error) with
      | Some filter, _ -> line (truncate m.width [ span `Dim "/"; span `Plain filter ])
      | None, Some e -> line (truncate m.width [ span `Err e ])
      | None, None -> line []
  in
  Mosaic.box ~flex_direction:Column
    ~size:(Mosaic.size_wh (Mosaic.pct 100) (Mosaic.pct 100))
    [ Mosaic.box ~flex_direction:Column ~flex_grow:1. ~flex_shrink:1. (List.map row rows); footer ]

let subscriptions _ =
  Mosaic.Sub.batch
    [
      Mosaic.Sub.on_key_all (fun k -> Some (Key k));
      Mosaic.Sub.on_mouse_all (fun ev -> Some (Mouse ev));
      Mosaic.Sub.on_resize (fun ~width ~height -> Resize (width, height));
    ]

let run ~standalone (opts : S.options) =
  let conn = Tmux.Client.connect opts.tmux ~client:opts.client in
  let init () =
    let m = make ~conn ~standalone (S.make ~now:Unix.gettimeofday opts) in
    (m, tick m)
  in
  let matrix =
    Matrix.create ~mode:`Alt ~exit_on_ctrl_c:false ~cursor_visible:false ~bracketed_paste:false
      ~focus_reporting:false ~kitty_keyboard:`Disabled ()
  in
  Fun.protect
    ~finally:(fun () -> Tmux.Client.close conn)
    (fun () -> Mosaic.run ~matrix { init; update; view; subscriptions })

let%test_module "Tests" =
  (module struct
    open View_fixture

    let run_info ?(kind = Run.Agent) ?(parent = "") ?outcome name : Sidebar.lingering =
      { name; parent = Test_fixture.owned parent; outcome; kind; started = test_at }

    let spans m line =
      let lead, title, tail = parts m line in
      lead @ title @ tail

    let row_text m line = String.concat "" (List.map (fun s -> s.text) (spans m line))

    let opts ?(dir = temp ()) () : Sidebar.options =
      {
        interval = Sidebar.default_interval;
        client = "";
        tmux = Tmux.create ();
        dir;
        threshold = 180.;
        grace = 30.;
      }

    let agent_pane ?run w p title = pane ~window:w ~title ?run p
    let shell_pane w p = pane ~window:w ~command:"zsh" p
    let agent_state id parent = (id, parent)

    let model ?(dir = temp ()) ?(clock = ref test_at) () =
      let m = Sidebar.make ~now:(fun () -> !clock) (opts ~dir ()) in
      { m with at = !clock }

    let empty_snap = (model ~dir:"" ()).snap

    let snap_of ?(l = []) panes =
      let state = state l panes in
      { empty_snap with Sidebar.state; visible = state }

    let server = Some (1, { Tmux.started_at = 1_700_000_000; pid = 42 })

    let rendered_model (m : Sidebar.model) =
      fst (Sidebar.step { m with snap = empty_snap } { m.snap with server })

    let rendered (m : Sidebar.model) = make ~standalone:false (rendered_model m)

    let rows ?(lingering = []) ?(current = "sess") ?(at = test_at) ?(pi = session "") panes st =
      let m = model ~dir:"" ~clock:(ref at) () in
      let lingering =
        lingering
        @ List.filter_map
            (fun (_, (id, parent)) ->
              if String.is_empty parent then None else Some (id, run_info ~parent ""))
            st
      in
      let l = List.map (fun (pane, (id, _)) -> (pane, (id, pi))) st in
      let snap =
        {
          (snap_of ~l panes) with
          client = client current;
          lingering = Sidebar.String_map.of_list lingering;
        }
      in
      let tui = rendered { m with snap } in
      Array.to_list tui.lines |> List.map (row_text tui)

    let render ?lingering ?current ?at ?pi panes st =
      List.iter print_endline (rows ?lingering ?current ?at ?pi panes st)

    let%expect_test "a subagent's window nests under the pane that spawned it" =
      render
        [
          agent_pane "@13" "%22" "orchestrator";
          shell_pane "@13" "%47";
          agent_pane "@20" "%30" "subagent";
        ]
        [ ("%22", agent_state "root-sess" ""); ("%30", agent_state "kid-sess" "root-sess") ];
      [%expect
        {|
        sess
        ┌◼orchestrator
        │ └◼subagent 0s
        └ zsh
        |}]

    let%expect_test "field() keeps the three cases aligned" =
      render
        [ agent_pane "@1" "%1" "orchestrator"; pane ~title:"idle-agent" "%2"; shell_pane "@1" "%3" ]
        [ ("%1", agent_state "root-sess" ""); ("%2", agent_state "idle-sess" "") ];
      [%expect {|
    sess
    ┌◼orchestrator
    ├◼idle-agent
    └ zsh
    |}]

    let%expect_test "sibling subagents form one group" =
      render
        [
          agent_pane "@13" "%22" "orchestrator";
          shell_pane "@13" "%47";
          agent_pane "@20" "%30" "subagent-a";
          agent_pane "@21" "%31" "subagent-b";
          agent_pane "@22" "%32" "subagent-c";
        ]
        [
          ("%22", agent_state "root-sess" "");
          ("%30", agent_state "kid-a-sess" "root-sess");
          ("%31", agent_state "kid-b-sess" "root-sess");
          ("%32", agent_state "kid-c-sess" "root-sess");
        ];
      [%expect
        {|
        sess
        ┌◼orchestrator
        │ ├◼subagent-a 0s
        │ ├◼subagent-b 0s
        │ └◼subagent-c 0s
        └ zsh
        |}]

    let%expect_test "a two-pane sibling keeps its own bracket beside the group glyph" =
      render
        [
          agent_pane "@13" "%22" "orchestrator";
          agent_pane "@20" "%30" "subagent-a";
          shell_pane "@20" "%40";
          agent_pane "@21" "%31" "subagent-b";
        ]
        [
          ("%22", agent_state "root-sess" "");
          ("%30", agent_state "kid-a-sess" "root-sess");
          ("%31", agent_state "kid-b-sess" "root-sess");
        ];
      [%expect
        {|
        sess
        ╶◼orchestrator
          ├┌◼subagent-a 0s
          │└ zsh
          └◼subagent-b 0s
        |}]

    let%expect_test "groups at depth two" =
      render
        [
          agent_pane "@1" "%1" "root";
          agent_pane "@2" "%2" "subagent-a";
          agent_pane "@3" "%3" "subagent-b";
          agent_pane "@4" "%4" "grandkid-a1";
          agent_pane "@5" "%5" "grandkid-b1";
          agent_pane "@6" "%6" "grandkid-b2";
        ]
        [
          ("%1", agent_state "root-sess" "");
          ("%2", agent_state "a-sess" "root-sess");
          ("%3", agent_state "b-sess" "root-sess");
          ("%4", agent_state "a1-sess" "a-sess");
          ("%5", agent_state "b1-sess" "b-sess");
          ("%6", agent_state "b2-sess" "b-sess");
        ];
      [%expect
        {|
        sess
        ╶◼root
          ├◼subagent-a 0s
          │ └◼grandkid-a1 0s
          └◼subagent-b 0s
            ├◼grandkid-b1 0s
            └◼grandkid-b2 0s
        |}]

    let%expect_test "two root agents in one window are the window's own bracket" =
      render
        [ agent_pane "@1" "%1" "first"; agent_pane "@1" "%2" "second" ]
        [ ("%1", agent_state "first-sess" ""); ("%2", agent_state "second-sess" "") ];
      [%expect {|
    sess
    ┌◼first
    └◼second
    |}]

    let%expect_test
        "the parent's column is carried across a nested child, and stops at the last pane" =
      render
        [
          shell_pane "@13" "%10";
          agent_pane "@13" "%22" "orchestrator";
          shell_pane "@13" "%47";
          agent_pane "@20" "%30" "subagent";
          shell_pane "@20" "%31";
        ]
        [ ("%22", agent_state "root-sess" ""); ("%30", agent_state "kid-sess" "root-sess") ];
      render
        [
          shell_pane "@13" "%10";
          agent_pane "@13" "%22" "orchestrator";
          agent_pane "@20" "%30" "subagent";
        ]
        [ ("%22", agent_state "root-sess" ""); ("%30", agent_state "kid-sess" "root-sess") ];
      [%expect
        {|
        sess
        ┌ zsh
        ├◼orchestrator
        │ └┌◼subagent 0s
        │  └ zsh
        └ zsh
        sess
        ┌ zsh
        └◼orchestrator
          └◼subagent 0s
        |}]

    let%expect_test
        "nesting is the walk's, not the reported depth's; an orphan is a root; a cycle drops nobody"
        =
      render
        [ agent_pane "@1" "%1" "root"; agent_pane "@2" "%2" "kid"; agent_pane "@3" "%3" "grandkid" ]
        [
          ("%1", agent_state "root-sess" "");
          ("%2", agent_state "kid-sess" "root-sess");
          ("%3", agent_state "gk-sess" "kid-sess");
        ];
      render
        [ agent_pane "@1" "%1" "unrelated"; agent_pane "@2" "%2" "orphan" ]
        [ ("%1", agent_state "other-sess" ""); ("%2", agent_state "orphan-sess" "elsewhere-sess") ];
      render
        [ agent_pane "@1" "%207" "a"; agent_pane "@2" "%208" "b" ]
        [ ("%207", agent_state "a-sess" "b-sess"); ("%208", agent_state "b-sess" "a-sess") ];
      [%expect
        {|
        sess
        ╶◼root
          └◼kid 0s
            └◼grandkid 0s
        sess
        ╶◼unrelated
        ╶◼orphan 0s
        sess
        ╶◼a 0s
          └◼b 0s
        |}]

    let%expect_test "the same state renders the same rows every time" =
      let panes =
        [
          agent_pane "@1" "%1" "root";
          shell_pane "@1" "%2";
          agent_pane "@2" "%3" "kid-a";
          agent_pane "@3" "%4" "kid-b";
          agent_pane "@4" "%5" "grandkid";
        ]
      in
      let st =
        [
          ("%1", agent_state "root-sess" "");
          ("%3", agent_state "a-sess" "root-sess");
          ("%4", agent_state "b-sess" "root-sess");
          ("%5", agent_state "g-sess" "b-sess");
        ]
      in
      let rows () = rows panes st in
      let want = rows () in
      Printf.printf "stable: %b\n"
        (List.for_all (fun _ -> List.equal String.equal (rows ()) want) (List.range 1 20));
      List.iter print_endline want;
      [%expect
        {|
        stable: true
        sess
        ┌◼root
        │ ├◼kid-a 0s
        │ └◼kid-b 0s
        │   └◼grandkid 0s
        └ zsh
        |}]

    let%expect_test
        "a lingering subagent shows its own name, dead or alive, and its outcome once recorded" =
      let lingering = [ ("helper", run_info "fix the flaky test") ] in
      render ~lingering [ pane ~window:"@20" ~dead_at:1. ~run:"helper" "%30" ] [];
      render ~lingering [ pane ~window:"@20" ~run:"helper" "%30" ] [];
      render ~lingering [ pane ~window:"@20" ~run:"helper" "%30"; shell_pane "@20" "%31" ] [];
      List.iter
        (fun outcome ->
          render
            ~lingering:[ ("helper", run_info ~outcome "subagent") ]
            [ pane ~window:"@20" ~dead_at:1. ~run:"helper" "%30" ]
            [])
        [ Run.Completed; Failed; Died; Stopped ];
      render [ pane ~window:"@20" ~dead_at:1. ~run:"no-such-run" "%30" ] [];
      [%expect
        {|
    sess
    ╶×fix the flaky test
    sess
    ╶◼fix the flaky test 0s
    sess
    ┌◼fix the flaky test 0s
    └ zsh
    sess
    ╶✓subagent completed
    sess
    ╶×subagent failed
    sess
    ╶×subagent died
    sess
    ╶×subagent stopped
    sess
    ╶
    |}]

    let%expect_test "a running bash run shows its elapsed time, and its outcome once it ended" =
      List.iter
        (fun d ->
          render
            ~lingering:[ ("build", run_info ~kind:Bash "build") ]
            ~at:(test_at +. d)
            [ pane ~window:"@20" ~run:"build" "%30" ]
            [])
        [ 0.; 65. ];
      render
        ~lingering:[ ("build", run_info ~kind:Bash ~outcome:Completed "build") ]
        ~at:(test_at +. 65.)
        [ pane ~window:"@20" ~dead_at:1. ~run:"build" "%30" ]
        [];
      [%expect
        {|
    sess
    ╶◼build 0s
    sess
    ╶◼build 1m05s
    sess
    ╶✓build completed
    |}]

    let%expect_test "a live subagent uses its run start unless it has activity text" =
      let panes = [ agent_pane ~run:"helper" "@20" "%30" "helper" ] in
      List.iter
        (fun activity ->
          render
            ~lingering:[ ("helper", run_info "helper") ]
            ~at:(test_at +. 65.)
            ~pi:(session ~activity ~ts:(test_at +. 60.) "")
            panes
            [ ("%30", agent_state "helper" "") ])
        [ ""; "checking tests"; "" ];
      [%expect
        {|
    sess
    ╶◼helper 1m05s
    sess
    ╶◼helper checking tests
    sess
    ╶◼helper 1m05s
    |}]

    let%expect_test
        "elapsed time is compact: seconds, then minutes and seconds, then hours and minutes" =
      List.iter
        (fun s -> Printf.printf "%g %s\n" s (elapsed s))
        [ -3.; 0.; 0.99; 1.; 59.9; 60.; 65.; 3599.; 3600.; 3720.; 90000. ];
      [%expect
        {|
    -3 0s
    0 0s
    0.99 0s
    1 1s
    59.9 59s
    60 1m00s
    65 1m05s
    3599 59m59s
    3600 1h00m
    3720 1h02m
    90000 25h00m
    |}]

    (* With the interval alone, a displayed second changes up to a whole tick late. *)
    let%expect_test "a live run wakes the tick at its next second boundary" =
      let clock = ref test_at in
      List.iter
        (fun (at, kind) ->
          clock := test_at +. at;
          let side, _ =
            Sidebar.step (model ~dir:"" ~clock ())
              {
                (snap_of [ pane ~window:"@20" ~run:"helper" "%30" ]) with
                client = client "sess";
                lingering = Sidebar.String_map.singleton "helper" (run_info ~kind "helper");
              }
          in
          Printf.printf "%.3f\n" (next_wait (make ~standalone:false side)))
        [ (2.3, Run.Bash); (2.95, Bash); (2.95, Agent) ];
      [%expect {|
    0.100
    0.050
    0.050
    |}]

    let%expect_test
        "a lingering subagent still nests, and a live split of a keepAlive pi is the bug report" =
      render
        ~lingering:[ ("helper", run_info ~parent:"root-sess" "subagent") ]
        [
          agent_pane "@13" "%22" "orchestrator"; pane ~window:"@20" ~dead_at:1. ~run:"helper" "%30";
        ]
        [ ("%22", agent_state "root-sess" "") ];
      render
        [
          agent_pane "@13" "%22" "working-on-kido";
          shell_pane "@20" "%5";
          agent_pane "@20" "%4" "helper";
        ]
        [ ("%22", agent_state "root-sess" ""); ("%4", agent_state "helper-sess" "root-sess") ];
      render
        [
          agent_pane "@13" "%21" "top-level";
          agent_pane "@13" "%101" "second";
          agent_pane "@20" "%30" "subagent-b";
        ]
        [
          ("%21", agent_state "top-sess" "");
          ("%101", agent_state "second-sess" "");
          ("%30", agent_state "kid-sess" "second-sess");
        ];
      [%expect
        {|
        sess
        ╶◼orchestrator
          └×subagent
        sess
        ╶◼working-on-kido
          └┌◼helper 0s
           └ zsh
        sess
        ┌◼top-level
        └◼second
          └◼subagent-b 0s
        |}]

    (* The pane is driven through Update with a snapshot that never changes: the regression the pending
   gates exist for, since with them gone every assertion still describes a correct indicator while
   the row freezes because rebuild is never called. *)
    let%expect_test "the debounce and the stall both redraw on a quiet tick" =
      let clock = ref test_at in
      let m = ref (make ~standalone:false (model ~clock ())) in
      let green () =
        Array.exists
          (fun (l : line) ->
            match l with
            | Row (_, _, { pane; _ }) when Tmux.equal_pane_id pane (Tmux.pane_id_of_string "%1") ->
                List.exists (fun (s : span) -> String.equal s.text "◼") (spans !m l)
            | _ -> false)
          !m.lines
      in
      let snap running =
        let p =
          pane ~session:"alpha" ~command:"zsh" ~prompt:(test_at -. 1.) ~running ~start:test_at
            ?exit:(if running then None else Some (0, test_at))
            ~active:true "%1"
        in
        { (snap_of [ p ]) with client = client "alpha" }
      in
      let tick d running =
        clock := !clock +. d;
        m := fst (update (Snapshot (snap running)) !m);
        Printf.printf "+%.2fs %s: green=%b\n" d
          (if running then "running" else "stopped")
          (green ())
      in
      tick 0. true;
      tick 0.2 true;
      tick 1. false;
      tick 0.45 false;
      tick 0.1 false;
      let dir = temp () in
      let m =
        ref
          (make ~standalone:false
             { (model ~dir ~clock ()) with opts = { (opts ~dir ()) with threshold = 60. } })
      in
      let l = [ ("%1", ("i", session ~ts:!clock "")) ] in
      let snap =
        {
          (snap_of ~l [ pane ~session:"alpha" ~title:"wedged" ~active:true "%1" ]) with
          client = client "alpha";
        }
      in
      let stalled () =
        Array.exists
          (fun r -> List.exists (fun (s : span) -> String.equal s.text "!") (spans !m r))
          !m.lines
      in
      let tick d =
        clock := !clock +. d;
        m := fst (update (Snapshot snap) !m);
        Printf.printf "+%.0fs: stalled=%b\n" d (stalled ())
      in
      tick 0.;
      tick 30.;
      tick 30.;
      [%expect
        {|
    +0.00s running: green=false
    +0.20s running: green=true
    +1.00s stopped: green=true
    +0.45s stopped: green=true
    +0.10s stopped: green=false
    +0s: stalled=false
    +30s: stalled=false
    +30s: stalled=true
    |}]

    let activate active panes =
      List.map
        (fun (p : State.pane) ->
          { p with active = Option.exists (String.equal (Tmux.string_of_pane_id p.pane_id)) active })
        panes

    let drive ?(clock = ref test_at) () =
      let m = ref (make ~standalone:false (model ~clock ())) in
      let tick ?(d = 0.) ?active panes =
        clock := !clock +. d;
        m :=
          fst
            (update
               (Snapshot { (snap_of (activate active panes)) with server; client = client "alpha" })
               !m);
        Array.iter
          (fun l -> match l with Header _ -> () | _ -> print_endline (row_text !m l))
          !m.lines
      in
      tick

    let records json p =
      {
        p with
        State.program_status =
          Result.get_exn (Tmux.Program_status.parse ({|{"serial":|} ^ json ^ "}"));
      }

    let%expect_test "outcomes stay drawn until visited; child records always show their raw state" =
      let tick = drive () in
      let agent serial =
        records
          (Printf.sprintf
             {|%d,"records":[{"id":"","app":"claude-code","state":"done","msg":"RmluaXNoZWQ="},{"id":"a","state":"error","title":"Q2hlY2s="},{"id":"b","state":"done"}]|}
             serial)
          (pane ~session:"alpha" ~window:"@1" ~title:"claude" "%1")
      in
      let shell exit =
        pane ~session:"alpha" ~window:"@2" ~command:"zsh" ~prompt:(test_at +. 1.) ~start:test_at
          ~exit ~command_line:"false" "%2"
      in
      print_endline "-- unvisited";
      tick [ agent 1; shell (1, test_at +. 1.) ];
      print_endline "-- both visited";
      tick ~active:"%1" [ agent 1; shell (1, test_at +. 1.) ];
      tick ~active:"%2" [ agent 1; shell (1, test_at +. 1.) ];
      print_endline "-- an unrelated serial does not re-arm";
      tick ~active:"%2" [ agent 2; shell (1, test_at +. 1.) ];
      print_endline "-- an exit from before the sidebar started counts as seen";
      tick ~active:"%1" [ agent 2; shell (1, test_at -. 1.) ];
      print_endline "-- accepted: another exit in the same whole seconds is the seen one";
      tick ~active:"%2" [ agent 2; shell (1, test_at +. 2.) ];
      tick ~active:"%1" [ agent 2; shell (0, test_at +. 2.) ];
      [%expect
        {|
        -- unvisited
        ╶✓claude Finished
          ├◼Check
          └✓b
        ╶◼zsh
        -- both visited
        ╶ claude Finished
          ├◼Check
          └✓b
        ╶◼zsh
        ╶ claude Finished
          ├◼Check
          └✓b
        ╶ zsh
        -- an unrelated serial does not re-arm
        ╶ claude Finished
          ├◼Check
          └✓b
        ╶ zsh
        -- an exit from before the sidebar started counts as seen
        ╶ claude Finished
          ├◼Check
          └✓b
        ╶ zsh
        -- accepted: another exit in the same whole seconds is the seen one
        ╶ claude Finished
          ├◼Check
          └✓b
        ╶ zsh
        ╶ claude Finished
          ├◼Check
          └✓b
        ╶ zsh
        |}]

    let%expect_test "a seen report does not hide a later unseen failed command" =
      let clock = ref test_at in
      let m = ref (make ~standalone:false (model ~clock ())) in
      let tick ?(d = 0.) label active panes =
        clock := !clock +. d;
        m :=
          fst
            (update
               (Snapshot
                  { (snap_of (activate (Some active) panes)) with server; client = client "alpha" })
               !m);
        let row = Array.find_map (function Row (_, _, r) -> Some r | _ -> None) !m.lines in
        Printf.printf "%-14s %s\n" label
          (match Option.flat_map (indicator !m) row with
          | None -> "none"
          | Some Done -> "done"
          | Some Failed -> "failed"
          | Some Running -> "running"
          | Some _ -> "other")
      in
      let p ?exit ?(running = false) ~prompt start =
        records {|1,"records":[{"id":"","app":"make","state":"done"}]|}
          (pane ~session:"alpha" ~window:"@1" ~command:"zsh" ~prompt:(test_at +. prompt) ~running
             ~start:(test_at +. start) ?exit ~command_line:"false" "%1")
      in
      let other = pane ~session:"alpha" ~window:"@2" ~command:"zsh" "%2" in
      let built = p ~prompt:1. 0. ~exit:(0, test_at +. 1.) in
      tick "report done" "%2" [ built; other ];
      tick "seen" "%1" [ built; other ];
      tick "left" "%2" [ built; other ];
      tick "false starts" "%2" [ p ~prompt:1. ~running:true 2.; other ];
      tick ~d:0.05 "false failed" "%2" [ p ~prompt:2. 2. ~exit:(1, test_at +. 2.); other ];
      [%expect
        {|
        report done    done
        seen           none
        left           none
        false starts   none
        false failed   failed
        |}]

    let%expect_test "a finished run holds its green, and a new run inside the hold draws at once" =
      let clock = ref test_at in
      let tick = drive ~clock () in
      let p ?exit running start =
        pane ~session:"alpha" ~command:"zsh" ~prompt:(test_at -. 1.) ~running
          ~start:(test_at +. start) ?exit ~command_line:"make" "%1"
      in
      List.iter
        (fun (d, p) ->
          Printf.printf "+%.2fs " d;
          tick ~d ~active:"%1" [ p ])
        [
          (0., p true 0.);
          (0.25, p true 0.);
          (0.1, p false 0. ~exit:(0, test_at));
          (0.3, p false 0. ~exit:(0, test_at));
          (0.1, p true 1.);
          (0.15, p true 1.);
          (0.1, p true 1.);
          (0.1, p false 1. ~exit:(0, test_at +. 1.));
          (0.6, p false 1. ~exit:(0, test_at +. 1.));
        ];
      [%expect
        {|
        +0.00s ╶ zsh
        +0.25s ╶◼make
        +0.10s ╶◼zsh
        +0.30s ╶◼zsh
        +0.10s ╶◼zsh
        +0.15s ╶◼zsh
        +0.10s ╶◼make
        +0.10s ╶◼zsh
        +0.60s ╶ zsh
        |}]

    let%expect_test "labels and captions are composed from kind and status" =
      let tick = drive () in
      let at = test_at +. 1. in
      tick
        [
          pane ~session:"alpha" ~window:"@1" ~command:"zsh" "%1";
          pane ~session:"alpha" ~window:"@2" ~command:"zsh" ~prompt:at "%2";
          records
            {|1,"records":[{"id":"","app":"cargo","state":"working","progress":40,"title":"QnVpbGQ=","msg":"Y29tcGlsaW5n"}]|}
            (pane ~session:"alpha" ~window:"@3" ~command:"zsh" ~prompt:at "%3");
          pane ~session:"alpha" ~window:"@4" ~command:"vim" ~prompt:at ~start:at ~running:true
            ~alternate:true ~command_line:"vim x" "%4";
          {
            (pane ~session:"alpha" ~window:"@5" ~command:"ssh" ~prompt:at ~start:test_at
               ~command_line:"ssh box" "%5")
            with
            ssh = Some ("deploy", "box");
          };
          records
            {|1,"records":[{"id":"","app":"claude-code","state":"blocked","kind":"permission","msg":"QXBwcm92ZQ=="}]|}
            (pane ~session:"alpha" ~window:"@6" ~title:"" "%6");
        ];
      [%expect
        {|
        ╶ zsh
        ╶ zsh
        ╶◼Build compiling 40%
        ╶ vim
        ╶ ssh deploy@box
        ╶◆claude-code Approve
        |}]

    let%expect_test
        "the fuzzy filter keeps matching sessions, best first, and an agent title matches too" =
      let panes =
        [
          pane ~session:"alpha" ~window:"@1" ~command:"zsh" "%1";
          pane ~session:"beta" ~window:"@2" ~title:"π - kido" "%2";
          pane ~session:"gamma" ~window:"@3" ~command:"zsh" "%3";
        ]
      in
      let m = model () in
      let m =
        {
          m with
          snap = { (snap_of ~l:[ ("%2", ("i", session "")) ] panes) with client = client "alpha" };
        }
      in
      let show filter =
        let tui = rendered m in
        Printf.printf "%S: %s\n" filter
          (String.concat " | "
             (List.map (row_text tui) (Array.to_list (lines ~search:filter tui.side))))
      in
      show "";
      show "zz";
      show "kido";
      show "a";
      [%expect
        {|
    "": alpha | ╶ zsh | beta | ╶◼π - kido | gamma | ╶ zsh
    "zz":
    "kido": beta | ╶◼π - kido
    "a": alpha | ╶ zsh | gamma | ╶ zsh | beta | ╶◼π - kido
    |}]

    let%expect_test "a row wider than the sidebar is cut to its width, ellipsis included" =
      let show width texts =
        let cut =
          truncate width (List.map (fun text -> { text; style = Mosaic.Ansi.Style.default }) texts)
        in
        let text = String.concat "" (List.map (fun (s : span) -> s.text) cut) in
        Printf.printf "%d %S -> %S\n" width (String.concat "" texts) text
      in
      show 4 [ "ab"; "cd" ];
      show 4 [ "abcd"; "ef" ];
      show 4 [ "ab"; "cd"; "e" ];
      show 4 [ "abcdef" ];
      show 4 [ "ab"; "cdef" ];
      [%expect
        {|
    4 "abcd" -> "abcd"
    4 "abcdef" -> "abc\226\128\166"
    4 "abcde" -> "abc\226\128\166"
    4 "abcdef" -> "abc\226\128\166"
    4 "abcdef" -> "abc\226\128\166"
    |}]
  end)
