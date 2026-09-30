module S = Sidebar
module Style = Mosaic.Ansi.Style
module Color = Mosaic.Ansi.Color

type span = Mosaic.span = { text : string; style : Style.t }
type line = Header of { name : string; current : bool } | Row of S.row | Message of string

let lines (side : S.model) =
  match side.snap.err with
  | Some e -> [| Message e |]
  | None ->
      Array.of_list
        (List.concat_map
           (fun (s : S.section) ->
             Header { name = s.name; current = s.current } :: List.map (fun r -> Row r) s.rows)
           side.sessions)

type model = {
  side : S.model;
  lines : line array;
  conn : Tmux.Conn.t option;
  standalone : bool;
  cursor : int;
  top : int;
  width : int;
  height : int;
  status : string;
  g_pend : bool;
}

let make ?conn ~standalone side =
  {
    side;
    lines = lines side;
    conn;
    standalone;
    cursor = 0;
    top = 0;
    width = 0;
    height = 0;
    status = "";
    g_pend = false;
  }

(* Every style names its foreground: Mosaic's grid paints an explicit white on any cell left
   without one, which would override the user's theme. *)
let style : S.role -> Style.t = function
  | `Plain -> Style.make ~fg:Color.default ()
  | `Current -> Style.make ~fg:Color.default ~bold:true ()
  | `Proc -> Style.make ~fg:Color.white ()
  | `Dim -> Style.make ~fg:Color.bright_black ()
  | `Err -> Style.make ~fg:Color.red ()
  | `Running -> Style.make ~fg:Color.green ()
  | `Waiting -> Style.make ~fg:Color.yellow ~bold:true ()
  | `Compacting -> Style.make ~fg:Color.magenta ()
  | `Done -> Style.make ~fg:Color.green ~bold:true ()
  | `Stalled -> Style.make ~fg:Color.red ~bold:true ()

let span role text = { text; style = style role }
let plain = span `Plain
let styled (s : S.span) = span s.role s.text

let glyph : S.indicator -> span option = function
  | Status Running -> Some (span `Running "◼")
  | Status Waiting -> Some (span `Waiting "◆")
  | Status Compacting -> Some (span `Compacting "◌")
  | Status Idle -> None
  | Unknown -> Some (span `Dim "?")
  | Done -> Some (span `Done "✓")
  | Failed -> Some (span `Err "◼")
  | Stalled -> Some (span `Stalled "!")
  | Gone (Some Completed) -> Some (span `Dim "✓")
  | Gone _ -> Some (span `Dim "×")

let parts : line -> span list * span list * span list = function
  | Header h -> ([], [ span (if h.current then `Current else `Plain) h.name ], [])
  | Message e -> ([], [ span `Err e ], [])
  | Row r ->
      let tree =
        List.concat
          (List.mapi
             (fun i s ->
               (if i > 0 then [ plain " " ] else [])
               @ if String.is_empty s then [] else [ span `Dim s ])
             (String.split_on_char ' ' r.tree))
      in
      ( (tree
        @ match Option.flat_map glyph r.indicator with None -> [ plain " " ] | Some i -> [ i ]),
        List.map styled r.title,
        List.map styled r.tail )

let spans line =
  let lead, title, tail = parts line in
  lead @ title @ tail

let row_text line = String.concat "" (List.map (fun s -> s.text) (spans line))
let pane_of : line -> string option = function Row r -> Some r.pane | Header _ | Message _ -> None

let index_of m pane =
  Option.map fst
    (CCArray.find_idx (fun l -> Option.equal String.equal (pane_of l) (Some pane)) m.lines)

let selected m = Option.flat_map pane_of (CCArray.get_safe m.lines m.cursor)
let view_rows m = if m.height > 1 then m.height - 1 else Array.length m.lines
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
    else if Option.is_some (pane_of m.lines.(i)) then ensure_visible { m with cursor = i }
    else go (i + delta)
  in
  go (m.cursor + delta)

let focus m pane =
  match index_of m pane with Some cursor -> ensure_visible { m with cursor } | None -> m

let redraw m side =
  let prev = selected m in
  let m = { m with side; lines = lines side } in
  match side.snap.err with
  | Some _ -> { m with cursor = -1 }
  | None ->
      let m =
        match Option.flat_map (index_of m) prev with
        | Some cursor -> { m with cursor }
        | None -> move { m with cursor = -1 } 1
      in
      clamp_top m

let next_attention m delta =
  let n = Array.length m.lines in
  let wants i = Option.exists (S.attention m.side) (pane_of m.lines.(i)) in
  let rec go k i =
    if k = n then m
    else
      let i = (i + delta + n) mod n in
      if wants i then ensure_visible { m with cursor = i } else go (k + 1) i
  in
  if n = 0 then m else go 0 m.cursor

let set_search m search = redraw m (S.rebuild { m.side with search })

let release_focus m =
  match Tmux.Exec.release_side_focus m.side.opts.client with
  | Ok () -> focus m m.side.snap.active
  | Error e -> { m with status = e }

type msg =
  | Snapshot of S.snapshot
  | Key of Mosaic.Event.key
  | Mouse of Mosaic.Event.mouse
  | Resize of int * int

let jump m =
  match selected m with
  | None -> (m, Mosaic.Cmd.none)
  | Some pane -> (
      match Tmux.Exec.jump ~client:m.side.opts.client pane with
      | Error e -> ({ m with status = e }, Mosaic.Cmd.none)
      | Ok () ->
          let m = match m.side.search with Some _ -> focus (set_search m None) pane | None -> m in
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
    match m.side.search with
    | Some _ -> none (set_search m None)
    | None -> if m.standalone then (m, Mosaic.Cmd.quit) else none (release_focus m)
  in
  let cycle next =
    match
      Tmux.Exec.switch_window ~client:m.side.opts.client ~next
        (S.windows_in_order m.side.snap.panes m.side.snap.states m.side.snap.lingering)
    with
    | Ok () -> m
    | Error e -> { m with status = e }
  in
  match m.side.search with
  | Some filter when not (String.is_empty text) -> none (set_search m (Some (filter ^ text)))
  | _ -> (
      match e.key with
      | Down when e.modifier.shift -> none (cycle true)
      | Up when e.modifier.shift -> none (cycle false)
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
          match m.side.search with
          | None -> none m
          | Some "" -> none { m with side = { m.side with search = None } }
          | Some filter ->
              let rec last i =
                if i > 0 && Char.code filter.[i] land 0xc0 = 0x80 then last (i - 1) else i
              in
              none (set_search m (Some (String.sub filter 0 (last (String.length filter - 1))))))
      | _ when is '/' -> none (set_search m (Some ""))
      | _ when is 'n' -> none (next_attention m 1)
      | _ when is 'N' -> none (next_attention m (-1))
      | _ when is 'g' && not pend -> none { m with g_pend = true }
      | Home -> none (top m)
      | _ when is 'g' -> none (top m)
      | End -> none (bottom m)
      | _ when is 'G' -> none (bottom m)
      | _ -> none m)

let tick ?wait m =
  match m.conn with
  | None -> Mosaic.Cmd.none
  | Some conn ->
      let opts = m.side.opts and prev = m.side.snap in
      Mosaic.Cmd.perform (fun dispatch -> dispatch (Snapshot (S.poll ?wait ~opts conn prev)))

let update msg m =
  match msg with
  | Resize (width, height) -> (ensure_visible { m with width; height }, Mosaic.Cmd.none)
  | Snapshot snap ->
      let was = m.side.snap in
      let m =
        match S.step m.side snap with side, true -> redraw m side | side, false -> { m with side }
      in
      let m =
        let focused (s : S.snapshot) =
          Option.exists (fun (c : Tmux.Exec.client_state) -> c.focused) s.client
        in
        if
          ((not (String.equal snap.active was.active)) || (focused was && not (focused snap)))
          && not (String.is_empty snap.active)
        then focus m snap.active
        else m
      in
      (m, tick m)
  | Mouse ev -> (
      match Mosaic.Event.Mouse.kind ev with
      | Down { button = Left } -> (
          let i = m.top + Mosaic.Event.Mouse.y ev in
          match Option.flat_map pane_of (CCArray.get_safe m.lines i) with
          | Some _ -> jump { m with cursor = i }
          | None -> (m, Mosaic.Cmd.none))
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
    let lead, title, tail = parts m.lines.(i) in
    let title =
      if i = m.cursor then
        List.map (fun s -> { s with style = Style.with_inverse true s.style }) title
      else title
    in
    line (truncate m.width (lead @ title @ tail))
  in
  let footer =
    if not (String.is_empty m.status) then line (truncate m.width [ span `Err m.status ])
    else
      match m.side.search with
      | Some filter -> line (truncate m.width [ span `Dim "/"; plain filter ])
      | None -> line []
  in
  Mosaic.box ~flex_direction:Column
    ~size:(Mosaic.size_wh (Mosaic.pct 100) (Mosaic.pct 100))
    [
      Mosaic.box ~flex_direction:Column ~flex_grow:1. ~flex_shrink:1.
        (List.init (max 0 (min h (Array.length m.lines - m.top))) (fun k -> row (m.top + k)));
      footer;
    ]

let subscriptions _ =
  Mosaic.Sub.batch
    [
      Mosaic.Sub.on_key_all (fun k -> Some (Key k));
      Mosaic.Sub.on_mouse_all (fun ev -> Some (Mouse ev));
      Mosaic.Sub.on_resize (fun ~width ~height -> Resize (width, height));
    ]

let run ~standalone (opts : S.options) =
  let conn = Tmux.Conn.connect ?socket:opts.socket opts.client in
  let init () =
    let m = make ~conn ~standalone (S.make ~now:Unix.gettimeofday opts) in
    (m, tick ~wait:false m)
  in
  let matrix =
    Matrix.create ~mode:`Alt ~exit_on_ctrl_c:false ~cursor_visible:false ~bracketed_paste:false
      ~focus_reporting:false ~kitty_keyboard:`Disabled ()
  in
  Fun.protect
    ~finally:(fun () -> Tmux.Conn.close conn)
    (fun () -> Mosaic.run ~matrix { init; update; view; subscriptions })
