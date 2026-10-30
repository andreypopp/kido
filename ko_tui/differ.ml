type cell = { text : string; width : int; style : Ansi.Style.t } [@@deriving equal]
type t = { mutable cells : cell array; mutable cols : int }

let create () = { cells = [||]; cols = 0 }
let invalidate t = t.cells <- [||]

let draw t ~cols cells =
  if cols < 1 || Array.length cells mod cols <> 0 then invalid_arg "cell dimensions";
  let b = Buffer.create 4096 and old = t.cells in
  let force = t.cols <> cols || Array.length old <> Array.length cells in
  if force then Buffer.add_string b (Ansi.to_string Ansi.reset);
  let pos = ref (-1) and pen = ref None in
  Array.iteri
    (fun i c ->
      if c.width > 0 && (force || not (equal_cell old.(i) c)) then (
        if !pos <> i then
          Buffer.add_string b
            (Ansi.to_string (Ansi.cursor_position ~row:((i / cols) + 1) ~col:((i mod cols) + 1)));
        if not (Option.exists (Ansi.Style.equal c.style) !pen) then (
          Buffer.add_string b (Ansi.Style.sgr_sequence ?prev:!pen c.style);
          pen := Some c.style);
        Buffer.add_string b (if String.is_empty c.text then " " else c.text);
        pos := if (i mod cols) + c.width >= cols then -1 else i + c.width))
    cells;
  t.cells <- cells;
  t.cols <- cols;
  if Buffer.length b > 0 then Buffer.add_string b (Ansi.to_string Ansi.reset);
  Buffer.contents b

let%test_module "Tests" =
  (module struct
    let%expect_test "indexed, RGB and unchanged cells" =
      let t = create () in
      let style = Ansi.Style.make ~fg:(Ansi.Color.indexed 2) () in
      let cells = [| { text = "a"; width = 1; style }; { text = "b"; width = 1; style } |] in
      Printf.printf "%S\n" (draw t ~cols:2 cells);
      Printf.printf "%S\n" (draw t ~cols:2 cells);
      let cells = Array.copy cells in
      cells.(1) <- { (cells.(1)) with style = Ansi.Style.make ~fg:(Ansi.Color.of_rgb 1 2 3) () };
      Printf.printf "%S\n" (draw t ~cols:2 cells);
      [%expect
        {|
   "\027[0m\027[1;1H\027[38;5;2mab\027[0m"
   ""
   "\027[1;2H\027[38;2;1;2;3mb\027[0m"
   |}]

    let%expect_test "wide tails" =
      let t = create () in
      let c text width = { text; width; style = Ansi.Style.default } in
      Printf.printf "%S\n" (draw t ~cols:2 [| c "界" 2; c "" 0; c "x" 1; c "" 1 |]);
      [%expect {| "\027[0m\027[1;1H\231\149\140\027[2;1Hx \027[0m" |}]
  end)
