open Kido
module S = Kido.Sidebar
module Style = Mosaic.Ansi.Style
module Color = Mosaic.Ansi.Color

type span = Mosaic.span = { text : string; style : Style.t }

type line =
  | Header of { name : string; current : bool }
  | Row of string * Tmux.session_id * S.row
  | Program of string * S.program_row
  | Message of string
  | Ask of Ask.t * Tmux.pane_id option

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
    let rec programs prefix depth trailing rows =
      match rows with
      | [] -> ()
      | (r : S.program_row) :: rest ->
          let children, siblings =
            List.take_drop_while
              (fun (c : S.program_row) -> String.prefix ~pre:(r.id ^ "/") c.id)
              rest
          in
          let current_depth = List.length (String.split_on_char '/' r.id) in
          let nested = prefix ^ String.make (2 * (current_depth - depth)) ' ' in
          let stem = if List.is_empty siblings && not trailing then " " else "│" in
          let branch = if String.equal stem " " then "└" else "├" in
          out := Program (nested ^ branch, r) :: !out;
          programs (nested ^ stem ^ " ") (current_depth + 1) false children;
          programs prefix depth trailing siblings
    in
    programs nested 1 (not (List.is_empty item.children)) item.program_rows;
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

type mode = Windows | Asks

type model = {
  side : S.model;
  lines : line array;
  conn : Tmux.Client.t option;
  standalone : bool;
  cursor : int;
  top : int;
  width : int;
  height : int;
  status : string;
  g_pend : bool;
  mode : mode;
  search : string option;
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
    mode = Windows;
    search = None;
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
  | `Done -> Style.make ~fg:Color.green ~bold:true ()
  | `Stalled -> Style.make ~fg:Color.red ~bold:true ()

let span role text = { text; style = style role }
let plain = span `Plain
let styled (s : S.span) = span s.role s.text

let glyph : S.indicator -> span option = function
  | Status Running -> Some (span `Running "◼")
  | Status Waiting -> Some (span `Waiting "◆")
  | Status Idle -> None
  | Unknown -> Some (span `Dim "?")
  | Done -> Some (span `Done "✓")
  | Failed -> Some (span `Err "◼")
  | Stalled -> Some (span `Stalled "!")
  | Gone (Some Completed) -> Some (span `Dim "✓")
  | Gone _ -> Some (span `Dim "×")

let elapsed secs =
  let s = max 0 (Float.to_int secs) in
  if s < 60 then Printf.sprintf "%ds" s
  else if s < 3600 then Printf.sprintf "%dm%02ds" (s / 60) (s mod 60)
  else Printf.sprintf "%dh%02dm" (s / 3600) (s / 60 mod 60)

let parts ~now : line -> span list * span list * span list = function
  | Header h -> ([], [ span (if h.current then `Current else `Plain) h.name ], [])
  | Message e -> ([], [ span `Err e ], [])
  | Ask (a, pane) ->
      let role = if Option.is_none pane then `Dim else `Plain in
      ( [],
        [ span role (a.name ^ " " ^ Ask.string_of_id a.id) ],
        [ span role (" " ^ List.hd (String.split_on_char '\n' a.text)) ] )
  | Program (prefix, r) ->
      ( [ span `Dim prefix; Option.value ~default:(plain " ") (glyph r.indicator) ],
        [ plain r.title ],
        if String.is_empty r.caption then [] else [ plain " "; span `Dim r.caption ] )
  | Row (prefix, _, r) -> (
      let tree = if String.is_empty prefix then [] else [ span `Dim prefix ] in
      ( (tree
        @ match Option.flat_map glyph r.indicator with None -> [ plain " " ] | Some i -> [ i ]),
        List.map styled r.title,
        match r.caption with
        | Elapsed s -> [ plain " "; span `Dim (elapsed (now -. s)) ]
        | Text [] -> []
        | Text tail -> plain " " :: List.map styled tail ))

let spans ~now line =
  let lead, title, tail = parts ~now line in
  lead @ title @ tail

let row_text ~now line = String.concat "" (List.map (fun s -> s.text) (spans ~now line))

let pane_of : line -> Tmux.pane_id option = function
  | Row (_, _, r) -> Some r.pane
  | Ask (_, pane) -> pane
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
    | Ask (a, _) -> Some (`Ask a.id)
    | line -> Option.map (fun p -> `Pane p) (pane_of line)
  in
  let prev = Option.flat_map key (CCArray.get_safe m.lines m.cursor) in
  let drawn =
    match m.mode with
    | Windows -> lines ~search:(Option.get_or ~default:"" m.search) side
    | Asks ->
        Array.of_list
          (Header { name = "asks"; current = true }
          :: List.map
               (fun (a : S.ask) ->
                 Ask
                   ( a.ask,
                     match a.target with Live pane -> Some pane | Revivable | Unavailable -> None ))
               side.snap.asks)
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

let set_search m search = redraw { m with search } m.side

let request m req =
  try
    let opts = m.side.opts in
    (m, S.handle ~tmux:opts.tmux ~dir:opts.dir ~client:opts.client req)
  with
  | Sys_error e -> (m, Error e)
  | Unix.Unix_error (e, fn, arg) -> (m, Error (Fs.unix_message e fn arg))

let release_focus m =
  let m, response = request m S.Release_side_focus in
  match response with
  | Ok () -> Option.map_or ~default:m (focus m) m.side.snap.active
  | Error e -> { m with status = e }

type msg =
  | Snapshot of S.snapshot
  | Key of Mosaic.Event.key
  | Mouse of Mosaic.Event.mouse
  | Resize of int * int

let jump m =
  let req =
    match CCArray.get_safe m.lines m.cursor with
    | Some (Ask (a, _)) -> Some (S.Activate_ask a.id)
    | Some (Row (_, session, r)) -> Some (S.Jump { session; window = r.window; pane = r.pane })
    | _ -> None
  in
  match req with
  | None -> (m, Mosaic.Cmd.none)
  | Some req -> (
      let m, response = request m req in
      match response with
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
    let m, response = request m (S.Switch_window direction) in
    match response with Ok _ -> m | Error e -> { m with status = e }
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
          | Some (Ask (a, _)) -> (
              let m, response = request m (S.Delete_ask a.id) in
              match response with Ok () -> none m | Error e -> none { m with status = e })
          | _ -> none m)
      | _ when is '/' && match m.mode with Windows -> true | Asks -> false ->
          none (set_search m (Some ""))
      | _ when is 'n' -> none (next_attention m 1)
      | _ when is 'N' -> none (next_attention m (-1))
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
      | Row (_, _, { caption = Elapsed s; _ }) -> Float.min wait (1. -. Float.rem (now -. s) 1.)
      | Row _ | Program _ | Header _ | Message _ | Ask _ -> wait)
    m.side.opts.interval (shown m)

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
          Option.exists (fun (c : Tmux_pane.client_state) -> c.focused) s.client
        in
        if
          ((not (Option.equal Tmux.equal_pane_id snap.active was.active))
          || (focused was && not (focused snap)))
          && Option.is_some snap.active
        then
          match m.mode with Windows -> Option.map_or ~default:m (focus m) snap.active | Asks -> m
        else m
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
          [ { s with text = String.sub s.text 0 cut }; plain "…" ]
  in
  if width <= 0 || List.fold_left (fun x s -> x + measure s.text) 0 spans <= width then spans
  else go (width - 1) spans

let view m =
  let line spans =
    Mosaic.box ~flex_direction:Row
      ~size:(Mosaic.size_wh (Mosaic.pct 100) (Mosaic.px 1))
      (List.map (fun s -> Mosaic.text ~style:s.style ~selectable:false s.text) spans)
  in
  let row i =
    let lead, title, tail = parts ~now:m.side.at m.lines.(i) in
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
      match m.search with
      | Some filter -> line (truncate m.width [ span `Dim "/"; plain filter ])
      | None -> line []
  in
  Mosaic.box ~flex_direction:Column
    ~size:(Mosaic.size_wh (Mosaic.pct 100) (Mosaic.pct 100))
    [
      Mosaic.box ~flex_direction:Column ~flex_grow:1. ~flex_shrink:1. (List.map row (shown m));
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
    let agent_state id parent = (id, session ~parent "")

    let model ?(dir = temp ()) ?(clock = ref test_at) ?(started = test_at -. 3600.) () =
      let m = Sidebar.make ~now:(fun () -> !clock) (opts ~dir ()) in
      { m with started; at = !clock }

    let rendered_model (m : Sidebar.model) =
      fst (Sidebar.step { m with snap = Sidebar.empty } m.snap)

    let rendered_lines m = Array.to_list (lines (rendered_model m))

    let render ?dir ?(current = "sess") ?(at = test_at) panes st =
      let m = model ?dir ~clock:(ref at) () in
      let states = states st in
      let snap =
        {
          Sidebar.empty with
          client = client current;
          panes = with_programs states panes;
          states;
          lingering = Sidebar.lingering_subagents ~dir:m.opts.dir panes Sidebar.String_map.empty;
        }
      in
      List.iter (fun r -> print_endline (row_text ~now:m.at r)) (rendered_lines { m with snap })

    let%expect_test "a subagent's window nests under the pane that spawned it" =
      render
        [
          agent_pane "@13" "%22" "orchestrator";
          shell_pane "@13" "%47";
          agent_pane "@20" "%30" "subagent";
        ]
        [ ("%22", agent_state "root-sess" ""); ("%30", agent_state "kid-sess" "root-sess") ];
      [%expect {|
    sess
    ┌◼orchestrator
    │ └◼subagent
    └ zsh
    |}]

    let%expect_test "field() keeps the three cases aligned" =
      render
        [ agent_pane "@1" "%1" "orchestrator"; pane ~title:"idle-agent" "%2"; shell_pane "@1" "%3" ]
        [ ("%1", agent_state "root-sess" ""); ("%2", ("idle-sess", session "")) ];
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
    │ ├◼subagent-a
    │ ├◼subagent-b
    │ └◼subagent-c
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
      ├┌◼subagent-a
      │└ zsh
      └◼subagent-b
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
      ├◼subagent-a
      │ └◼grandkid-a1
      └◼subagent-b
        ├◼grandkid-b1
        └◼grandkid-b2
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
    │ └┌◼subagent
    │  └ zsh
    └ zsh
    sess
    ┌ zsh
    └◼orchestrator
      └◼subagent
    |}]

    let%expect_test
        "nesting is the walk's, not the reported depth's; an orphan is a root; a cycle drops nobody"
        =
      render
        [ agent_pane "@1" "%1" "root"; agent_pane "@2" "%2" "kid"; agent_pane "@3" "%3" "grandkid" ]
        [
          ("%1", agent_state "root-sess" "");
          ("%2", ("kid-sess", session ~parent:"root-sess" ~depth:1 ""));
          ("%3", ("gk-sess", session ~parent:"kid-sess" ~depth:1 ""));
        ];
      render
        [ agent_pane "@1" "%1" "unrelated"; agent_pane "@2" "%2" "orphan" ]
        [
          ("%1", agent_state "other-sess" "");
          ("%2", ("orphan-sess", session ~parent:"elsewhere-sess" ~depth:1 ""));
        ];
      render
        [ agent_pane "@1" "%207" "a"; agent_pane "@2" "%208" "b" ]
        [ ("%207", agent_state "a-sess" "b-sess"); ("%208", agent_state "b-sess" "a-sess") ];
      [%expect
        {|
    sess
    ╶◼root
      └◼kid
        └◼grandkid
    sess
    ╶◼unrelated
    ╶◼orphan
    sess
    ╶◼a
      └◼b
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
      let rows () =
        let m = model () in
        let states = states st in
        rendered_lines
          {
            m with
            snap =
              {
                Sidebar.empty with
                client = client "sess";
                panes = with_programs states panes;
                states;
              };
          }
        |> List.map (row_text ~now:m.at)
      in
      let want = rows () in
      Printf.printf "stable: %b\n"
        (List.for_all (fun _ -> List.equal String.equal (rows ()) want) (List.range 1 20));
      List.iter print_endline want;
      [%expect
        {|
    stable: true
    sess
    ┌◼root
    │ ├◼kid-a
    │ └◼kid-b
    │   └◼grandkid
    └ zsh
    |}]

    let%expect_test
        "a lingering subagent shows its own name, dead or alive, and its outcome once recorded" =
      let dir = temp () in
      let id = new_run ~dir "fix the flaky test" in
      render ~dir [ pane ~window:"@20" ~dead_at:1. ~run:id "%30" ] [];
      render ~dir [ pane ~window:"@20" ~run:id "%30" ] [];
      render ~dir [ pane ~window:"@20" ~run:id "%30"; shell_pane "@20" "%31" ] [];
      List.iter
        (fun result ->
          render ~dir
            [ pane ~window:"@20" ~dead_at:1. ~run:(new_run ~dir ~result "subagent") "%30" ]
            [])
        [ Subrun.Completed; Failed; Died; Stopped ];
      render ~dir [ pane ~window:"@20" ~dead_at:1. ~run:"no-such-run" "%30" ] [];
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
      let dir = temp () in
      let run = new_run ~dir ~kind:Bash "build" in
      List.iter
        (fun d -> render ~dir ~at:(test_at +. d) [ pane ~window:"@20" ~run "%30" ] [])
        [ 0.; 65. ];
      render ~dir ~at:(test_at +. 65.)
        [
          pane ~window:"@20" ~dead_at:1.
            ~run:(new_run ~dir ~kind:Bash ~result:Completed "build")
            "%30";
        ]
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
      let dir = temp () in
      let run = new_run ~dir "helper" in
      let panes = [ agent_pane ~run "@20" "%30" "helper" ] in
      List.iter
        (fun activity ->
          render ~dir ~at:(test_at +. 65.) panes
            [ ("%30", (run, session ~activity ~ts:(test_at +. 60.) "")) ])
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
      let dir = temp () in
      let clock = ref test_at in
      let wait panes =
        let side, _ =
          Sidebar.step (model ~dir ~clock ())
            {
              Sidebar.empty with
              client = client "sess";
              panes;
              lingering = Sidebar.lingering_subagents ~dir panes Sidebar.String_map.empty;
            }
        in
        Printf.printf "%.3f\n" (next_wait (make ~standalone:false side))
      in
      let bash = [ pane ~window:"@20" ~run:(new_run ~dir ~kind:Bash "build") "%30" ] in
      let agent = [ pane ~window:"@20" ~run:(new_run ~dir "helper") "%30" ] in
      List.iter
        (fun (at, panes) ->
          clock := test_at +. at;
          wait panes)
        [ (2.3, bash); (2.95, bash); (2.95, agent) ];
      [%expect {|
    0.100
    0.050
    0.050
    |}]

    let%expect_test
        "a lingering subagent still nests, and a live split of a keepAlive pi is the bug report" =
      let dir = temp () in
      let id = new_run ~dir ~parent:"root-sess" "subagent" in
      render ~dir
        [ agent_pane "@13" "%22" "orchestrator"; pane ~window:"@20" ~dead_at:1. ~run:id "%30" ]
        [ ("%22", agent_state "root-sess" "") ];
      render
        [
          agent_pane "@13" "%22" "working-on-kido";
          shell_pane "@20" "%5";
          agent_pane ~run:"run-1" "@20" "%4" "helper";
        ]
        [
          ("%22", agent_state "root-sess" "");
          ("%4", ("helper-sess", session ~parent:"root-sess" ""));
        ];
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
      └┌◼helper
       └ zsh
    sess
    ┌◼top-level
    └◼second
      └◼subagent-b
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
                List.exists (fun (s : span) -> String.equal s.text "◼") (spans ~now:!clock l)
            | _ -> false)
          !m.lines
      in
      let snap running =
        let p =
          pane ~session:"alpha" ~command:"zsh" ~prompt:(test_at -. 1.) ~running ~start:test_at
            ?exit:(if running then None else Some (0, test_at))
            "%1"
        in
        {
          Sidebar.empty with
          client = client "alpha";
          active = Some (Tmux.pane_id_of_string "%1");
          panes = [ p ];
        }
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
      let snap =
        {
          Sidebar.empty with
          client = client "alpha";
          active = Some (Tmux.pane_id_of_string "%1");
          panes =
            with_programs
              (states [ ("%1", ("i", session ~ts:!clock "")) ])
              [ pane ~session:"alpha" ~title:"wedged" "%1" ];
          states = states [ ("%1", ("i", session ~ts:!clock "")) ];
        }
      in
      let stalled () =
        Array.exists
          (fun r -> List.exists (fun (s : span) -> String.equal s.text "!") (spans ~now:!clock r))
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
          snap =
            {
              Sidebar.empty with
              client = client "alpha";
              panes = with_programs (states [ ("%2", ("i", session "")) ]) panes;
              states = states [ ("%2", ("i", session "")) ];
            };
        }
      in
      let show filter =
        Printf.printf "%S: %s\n" filter
          (String.concat " | "
             (List.map (row_text ~now:m.at)
                (Array.to_list (lines ~search:filter (rendered_model m)))))
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

    let%expect_test "every role names its foreground" =
      List.iter
        (fun r -> Format.printf "%a@." Mosaic.Ansi.Style.pp (style r))
        [ `Plain; `Current; `Proc; `Dim; `Err; `Running; `Waiting; `Done; `Stalled ];
      [%expect
        {|
    Style{fg=#000000}
    Style{fg=#000000, attrs=[Bold]}
    Style{fg=#c0c0c0}
    Style{fg=#808080}
    Style{fg=#800000}
    Style{fg=#008000}
    Style{fg=#808000, attrs=[Bold]}
    Style{fg=#008000, attrs=[Bold]}
    Style{fg=#800000, attrs=[Bold]}
    |}]
  end)
