type layout = {
  cols : int;
  rows : int;
  pane_x : int;
  pane_rows : int;
  warning : bool;
  dead : string option;
  sidebar : (string * bool) list;
  choosing : int option;
}
[@@deriving equal]

type cursor = Hidden | Visible of int * int * Ko_vt.cursor_shape [@@deriving equal]

type t = {
  differ : Differ.t;
  mutable layout : layout option;
  mutable frame : Ko_vt.frame option;
  mutable ui : Differ.cell array;
  mutable cursor : cursor option;
}

let create () = { differ = Differ.create (); layout = None; frame = None; ui = [||]; cursor = None }

let invalidate t =
  Differ.invalidate t.differ;
  t.layout <- None;
  t.cursor <- None

let style ~inverse = Ansi.Style.make ~fg:Ansi.Color.default ~bg:Ansi.Color.default ~inverse ()

let draw_line grid ~x ~y ~width ~inverse text =
  let width = max 0 width and style = style ~inverse in
  let p = Matrix.Text.find_wrap_pos ~width_method:`Unicode ~tab_width:8 text ~max_columns:width in
  Matrix.Grid.draw_text grid ~x ~y ~style ~text:(String.make width ' ');
  Matrix.Grid.draw_text grid ~x ~y ~style ~text:(String.sub text 0 p.byte_offset)

let draw_ui l grid =
  Matrix.Grid.clear grid;
  if l.pane_x > 0 then
    for y = 0 to l.pane_rows - 1 do
      draw_line grid ~x:0 ~y ~width:(l.pane_x - 1) ~inverse:false "";
      Matrix.Grid.draw_text grid ~x:(l.pane_x - 1) ~y ~style:(style ~inverse:false) ~text:"\u{2502}"
    done;
  List.iteri
    (fun y (text, selected) ->
      if y < l.pane_rows then
        draw_line grid ~x:0 ~y ~width:(l.pane_x - 1)
          ~inverse:(match l.choosing with Some i -> i = y | None -> selected)
          text)
    l.sidebar;
  Option.iter
    (draw_line grid ~x:l.pane_x ~y:(l.pane_rows - 1) ~width:(l.cols - l.pane_x) ~inverse:true)
    l.dead;
  if l.warning then
    draw_line grid ~x:0 ~y:(l.rows - 1) ~width:l.cols ~inverse:true
      "ko: extended keys were not confirmed; use sidebar mouse switching"

let native_style (c : Ko_vt.cell) =
  let colour = function
    | Ko_vt.Default -> Ansi.Color.default
    | Indexed n -> Ansi.Color.indexed n
    | Rgb (r, g, b) -> Ansi.Color.of_rgb r g b
  in
  let has = Ko_vt.has_attribute c.attrs in
  Ansi.Style.make ~fg:(colour c.fg) ~bg:(colour c.bg) ~bold:(has Bold) ~italic:(has Italic)
    ~underline:(has Underline) ~inverse:(has Inverse) ~dim:(has Dim) ~blink:(has Blink)
    ~hidden:(has Hidden) ~strikethrough:(has Strikethrough) ~overline:(has Overline) ()

let paint t ~modes ~layout:l ~frame =
  let ui_changed = not (Option.exists (equal_layout l) t.layout) in
  if ui_changed || not (Stdlib.( == ) t.frame frame) then (
    let shift = if Option.is_some l.dead then 1 else 0 in
    let live = max 0 (l.pane_rows - shift) in
    t.layout <- Some l;
    t.frame <- frame;
    if ui_changed then (
      let grid = Matrix.Grid.create ~width:l.cols ~height:l.rows () in
      draw_ui l grid;
      let blank = { Differ.text = ""; width = 1; style = Ansi.Style.default } in
      t.ui <-
        Array.init (l.cols * l.rows) (fun i ->
            let x = i mod l.cols and y = i / l.cols in
            if x >= l.pane_x && y < live then blank
            else
              let cell = Matrix.Grid.get_cell grid i in
              {
                Differ.text = Matrix.Grid.get_text grid i;
                width =
                  (if Matrix.Grid.Cell.is_continuation cell then 0
                   else max 1 (Matrix.Grid.Cell.grapheme_width cell));
                style =
                  Ansi.Style.with_attrs
                    (Ansi.Attr.unpack (Matrix.Grid.get_attrs grid i))
                    (Ansi.Style.make ~fg:(Matrix.Grid.get_fg grid i) ~bg:(Matrix.Grid.get_bg grid i)
                       ());
              }));
    let previous = ref None in
    let style (c : Ko_vt.cell) =
      match !previous with
      | Some (old, value)
        when Ko_vt.equal_colour old.Ko_vt.fg c.fg
             && Ko_vt.equal_colour old.bg c.bg
             && Ko_vt.equal_attributes old.attrs c.attrs ->
          value
      | _ ->
          let value = native_style c in
          previous := Some (c, value);
          value
    in
    let cells = Array.copy t.ui in
    Option.iter
      (fun (f : Ko_vt.frame) ->
        for y = 0 to min live (f.rows - shift) - 1 do
          for x = 0 to min (l.cols - l.pane_x) f.cols - 1 do
            let c = f.cells.(((y + shift) * f.cols) + x) in
            let clipped = c.width = 2 && x + l.pane_x = l.cols - 1 in
            cells.((y * l.cols) + x + l.pane_x) <-
              {
                Differ.text = (if clipped then "" else c.text);
                width = (if clipped then 1 else c.width);
                style = style c;
              }
          done
        done)
      frame;
    let b = Buffer.create 4096 in
    Option.iter (fun f -> Buffer.add_string b (Modes.apply modes f)) frame;
    let output = Differ.draw t.differ ~cols:l.cols cells in
    Buffer.add_string b output;
    let cursor =
      match frame with
      | Some f
        when Option.is_none l.dead && f.cursor_visible
             && f.cursor_x < l.cols - l.pane_x
             && f.cursor_y < l.pane_rows ->
          Visible (l.pane_x + f.cursor_x, f.cursor_y, f.cursor_shape)
      | _ -> Hidden
    in
    if (not (String.is_empty output)) || not (Option.exists (equal_cursor cursor) t.cursor) then (
      (match cursor with
      | Hidden -> Buffer.add_string b (Ansi.to_string (Ansi.disable Cursor_visible))
      | Visible (x, y, shape) ->
          Buffer.add_string b
            (Ansi.to_string
               (Ansi.cursor_style
                  ~shape:
                    (match shape with
                    | Ko_vt.Bar -> `Bar
                    | Underline -> `Underline
                    | Block | Hollow_block -> `Block)));
          Buffer.add_string b (Ansi.to_string (Ansi.cursor_position ~row:(y + 1) ~col:(x + 1)));
          Buffer.add_string b (Ansi.to_string (Ansi.enable Cursor_visible)));
      t.cursor <- Some cursor);
    if Buffer.length b > 0 then
      Modes.output
        (Ansi.to_string (Ansi.enable Sync_output)
        ^ Buffer.contents b
        ^ Ansi.to_string (Ansi.disable Sync_output));
    true)
  else false

let%test_module "Tests" =
  (module struct
    let%expect_test "only the highlighted row is reversed and the bar sits left of the pane" =
      let grid = Matrix.Grid.create ~width:30 ~height:2 () in
      draw_ui
        {
          cols = 30;
          rows = 2;
          pane_x = 25;
          pane_rows = 2;
          warning = false;
          dead = None;
          sidebar = [ ("1 界", true); ("2 /tmp", false) ];
          choosing = Some 1;
        }
        grid;
      let inverse i = Ansi.Attr.mem Inverse (Ansi.Attr.unpack (Matrix.Grid.get_attrs grid i)) in
      for y = 0 to 1 do
        let count =
          List.length (List.filter (fun x -> inverse ((y * 30) + x)) (List.init 30 Fun.id))
        in
        Printf.printf "row %d: %d reversed; bar=%s\n" y count
          (Matrix.Grid.get_text grid ((y * 30) + 24))
      done;
      [%expect {|
        row 0: 0 reversed; bar=│
        row 1: 24 reversed; bar=│
      |}]

    let%expect_test "a one-column terminal draws no negative width" =
      let grid = Matrix.Grid.create ~width:1 ~height:1 () in
      draw_ui
        {
          cols = 1;
          rows = 1;
          pane_x = Sidebar.pane_x ~cols:1;
          pane_rows = 1;
          warning = true;
          dead = Some "[exited 1]";
          sidebar = [ ("1 sh", true) ];
          choosing = None;
        }
        grid;
      print_string (Matrix.Grid.get_text grid 0);
      [%expect {| k |}]
  end)
