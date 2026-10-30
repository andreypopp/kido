type t
type format = Plain | Vt
type colour = Default | Indexed of int | Rgb of int * int * int [@@deriving equal]
type attributes = int [@@deriving equal]

type attribute =
  | Bold
  | Italic
  | Underline
  | Inverse
  | Dim
  | Blink
  | Hidden
  | Strikethrough
  | Overline

let has_attribute attrs flag =
  (attrs
  land 1
       lsl
       match flag with
       | Bold -> 0
       | Italic -> 1
       | Underline -> 2
       | Inverse -> 3
       | Dim -> 4
       | Blink -> 5
       | Hidden -> 6
       | Strikethrough -> 7
       | Overline -> 8)
  <> 0

type cursor_shape = Bar | Block | Underline | Hollow_block [@@deriving equal]
type mouse_tracking = Off | Press | Button | Any [@@deriving equal]
type cell = { text : string; width : int; fg : colour; bg : colour; attrs : attributes }

type frame = {
  cols : int;
  rows : int;
  cells : cell array;
  cursor_x : int;
  cursor_y : int;
  cursor_visible : bool;
  cursor_shape : cursor_shape;
  mouse : mouse_tracking;
  keyboard : int;
}

external close : t -> unit = "ko_vt_close"
external hold_id : t -> int = "ko_vt_hold_id"
external render_delay : t -> float = "ko_vt_render_delay"
external render : t -> frame = "ko_vt_render"
external scroll : t -> int -> unit = "ko_vt_scroll"
external bottom : t -> bool = "ko_vt_bottom"

external create :
  cols:int ->
  rows:int ->
  scrollback_max_bytes:int ->
  apc_max_bytes:int ->
  kitty_image_storage_limit:int ->
  continuation_max_bytes:int ->
  t = "ko_vt_create_bytecode" "ko_vt_create"

external configure :
  t ->
  scrollback_max_bytes:int ->
  apc_max_bytes:int ->
  kitty_image_storage_limit:int ->
  continuation_max_bytes:int ->
  unit = "ko_vt_configure"

external write : t -> ?off:int -> ?len:int -> string -> unit = "ko_vt_write"
external resize : t -> cols:int -> rows:int -> unit = "ko_vt_resize"
external dump : t -> format -> string = "ko_vt_dump"
external dump_history : t -> format -> string = "ko_vt_dump_history"
external snapshot : t -> screen:bool -> images:bool -> string = "ko_vt_snapshot"
external decode : ?ready:(string -> unit) -> (int -> string) -> full:bool -> t = "ko_vt_decode"
external cursor : t -> int * int * bool = "ko_vt_cursor"
external mode : t -> int -> bool = "ko_vt_mode"
external total_rows : t -> int = "ko_vt_total_rows"

let string_reader ?(chunk = max_int) bytes =
  let offset = ref 0 in
  fun capacity ->
    let len = min chunk (min capacity (String.length bytes - !offset)) in
    let piece = String.sub bytes !offset len in
    offset := !offset + len;
    piece

let decode_string ?ready ~full bytes = decode ?ready ~full (string_reader bytes)

let%test_module "Tests" =
  (module struct
    let create ~cols ~rows =
      create ~cols ~rows
        ~scrollback_max_bytes:(32 * 1024 * 1024)
        ~apc_max_bytes:(65 * 1024 * 1024)
        ~kitty_image_storage_limit:10_000_000
        ~continuation_max_bytes:(65 * 1024 * 1024)

    let tags bytes =
      let rec go pos acc =
        if pos + 10 > String.length bytes then List.rev acc
        else
          let tag = Char.code bytes.[pos] lor (Char.code bytes.[pos + 1] lsl 8) in
          let len =
            Char.code bytes.[pos + 2]
            lor (Char.code bytes.[pos + 3] lsl 8)
            lor (Char.code bytes.[pos + 4] lsl 16)
            lor (Char.code bytes.[pos + 5] lsl 24)
          in
          go (pos + 10 + len) (tag :: acc)
      in
      go 10 []

    let%expect_test "kitty payload filtered, screen cut at READY, mode 2026 cleared" =
      let server = create ~cols:20 ~rows:5 in
      write server "\027_Ga=T,f=32,s=1,v=1,i=1;AQIDBA==\027\\\027[?2026himage";
      let print_tags label bytes =
        Printf.printf "%s: %s\n" label (String.concat " " (List.map string_of_int (tags bytes)))
      in
      print_tags "all" (snapshot server ~screen:false ~images:true);
      let filtered = snapshot server ~screen:false ~images:false in
      print_tags "no images" filtered;
      print_tags "screen" (snapshot server ~screen:true ~images:true);
      let restored = decode ~full:true (string_reader ~chunk:7 filtered) in
      Printf.printf "server_sync=%b mirror_sync=%b\n" (mode server 2026) (mode restored 2026);
      write server "\027[?2026l";
      Printf.printf "equal after server ends sync=%b\n"
        (String.equal (dump server Vt) (dump restored Vt));
      (try ignore (decode ~full:true (fun _ -> failwith "reader stopped"))
       with Failure message -> print_endline message);
      [%expect
        {|
        all: 1 2 3 8 7 5 9 4 6
        no images: 1 2 3 8 7 5 4 6
        screen: 1 2 3 8 7 5
        server_sync=true mirror_sync=false
        equal after server ends sync=true
        reader stopped
        |}]

    let%expect_test "state open at a snapshot" =
      let osc8 i =
        Printf.sprintf "\027]8;;https://example.org/%d\027\\link %d\027]8;;\027\\\r\n" i i
      in
      List.iter
        (fun (label, before, after) ->
          let server = create ~cols:30 ~rows:6 in
          write server before;
          let screen =
            decode ~full:false (string_reader (snapshot server ~screen:true ~images:false))
          in
          let full =
            decode ~full:true (string_reader (snapshot server ~screen:false ~images:false))
          in
          List.iter (fun t -> write t after) [ server; screen; full ];
          let same t = String.equal (dump server Vt) (dump t Vt) in
          Printf.printf "%s: screen=%b full=%b plain=%b\n" label (same screen) (same full)
            (String.equal (dump server Plain) (dump screen Plain)
            && String.equal (dump server Plain) (dump full Plain)))
        [
          ("open hyperlink", "\027]8;;https://example.org\027\\ab", "cd\027]8;;\027\\ ef");
          ("pen", "\027[1;31mab", "cd");
          ("pending wrap", String.make 30 'x', "y");
          ("charset", "\027(0ab", "qq");
          ("inside OSC 8 uri", "\027]8;;file:///tmp/1", "06\027\\/tmp/106\027]8;;\027\\ ef");
          ("alternate screen", "primary\r\n\027[?1049halt", "\027[?1049l");
          ( "OSC 8 rows scrolled after decode",
            osc8 0,
            String.concat "" (List.init 8 (fun i -> osc8 (i + 1))) );
        ];
      [%expect
        {|
        open hyperlink: screen=true full=true plain=true
        pen: screen=true full=true plain=true
        pending wrap: screen=true full=true plain=true
        charset: screen=true full=true plain=true
        inside OSC 8 uri: screen=true full=true plain=true
        alternate screen: screen=true full=true plain=true
        OSC 8 rows scrolled after decode: screen=false full=false plain=true
        |}]

    let%expect_test "full mirror applies resizes, partial mirror decodes a screen" =
      let server = create ~cols:20 ~rows:5 in
      let mirror = create ~cols:20 ~rows:5 in
      for i = 0 to 99 do
        let bytes =
          Printf.sprintf "\027]8;;https://example.org/%d\027\\line %d\027]8;;\027\\\r\n" i i
        in
        write server bytes;
        write mirror bytes
      done;
      List.iter
        (fun (cols, rows) ->
          resize server ~cols ~rows;
          resize mirror ~cols ~rows;
          let partial =
            decode ~full:false (string_reader ~chunk:7 (snapshot server ~screen:true ~images:false))
          in
          Printf.printf "%b %b %b\n"
            (String.equal (dump server Vt) (dump mirror Vt))
            (String.equal (dump server Vt) (dump partial Vt))
            (Stdlib.( = ) (cursor server) (cursor partial)))
        [ (10, 8); (40, 3); (20, 5) ];
      [%expect {|
        true true true
        true true true
        true true true
        |}]

    let%expect_test "READY publishes a screen before full history" =
      let server = create ~cols:16 ~rows:2 in
      for i = 0 to 9999 do
        write server (Printf.sprintf "line%05d\r\n" i)
      done;
      let ready_rows = ref 0 and calls = ref 0 in
      let restored =
        decode ~full:true
          ~ready:(fun bytes ->
            incr calls;
            let screen = decode_string ~full:false bytes in
            ready_rows := total_rows screen;
            close screen)
          (string_reader (snapshot server ~screen:false ~images:false))
      in
      Printf.printf "callbacks=%d ready_has_less_history=%b full_rows=%d\n" !calls
        (!ready_rows < total_rows restored)
        (total_rows restored);
      close server;
      close restored;
      [%expect {| callbacks=1 ready_has_less_history=true full_rows=10001 |}]

    let%expect_test "synchronized output keeps the frame at the start of the hold" =
      let vt = create ~cols:8 ~rows:2 in
      write vt "old\027[?2026h\rnew";
      Printf.printf "%s\n" (render vt).cells.(0).text;
      write vt "\027[?2026l";
      Printf.printf "%s\n" (render vt).cells.(0).text;
      [%expect {|
        o
        n
      |}]

    let%expect_test "render keeps palette indices, RGB overrides, wide tails and viewport modes" =
      let server = create ~cols:8 ~rows:2 in
      write server
        "first\r\n\
         second\r\n\
         \027[32;48;2;1;2;3m界x\027[?1h\027[?1000h\027[?1002h\027[?1006h\027[?1004h\027[?2004h\027[=3;1u";
      let vt = decode ~full:true (string_reader (snapshot server ~screen:false ~images:false)) in
      List.iter (fun n -> assert (mode vt n)) [ 1; 1002; 1004; 1006; 2004 ];
      let f = render vt in
      Printf.printf "%d %d mouse=%s keyboard=%d\n" f.cols f.rows
        (match f.mouse with Button -> "button" | _ -> assert false)
        f.keyboard;
      let colour = function
        | Default -> "default"
        | Indexed n -> Printf.sprintf "index:%d" n
        | Rgb (r, g, b) -> Printf.sprintf "rgb:%d,%d,%d" r g b
      in
      Array.iteri
        (fun i c ->
          if not (String.is_empty c.text) then
            Printf.printf "%d %S width=%d fg=%s bg=%s\n" i c.text c.width (colour c.fg)
              (colour c.bg))
        f.cells;
      scroll vt (-1);
      Printf.printf "scrolled=%S\n" (render vt).cells.(0).text;
      ignore (bottom vt);
      Printf.printf "bottom=%S\n" (render vt).cells.(0).text;
      close server;
      close vt;
      close vt;
      (try ignore (render vt) with Invalid_argument message -> print_endline message);
      [%expect
        {|
        8 2 mouse=button keyboard=3
        0 "s" width=1 fg=default bg=default
        1 "e" width=1 fg=default bg=default
        2 "c" width=1 fg=default bg=default
        3 "o" width=1 fg=default bg=default
        4 "n" width=1 fg=default bg=default
        5 "d" width=1 fg=default bg=default
        8 "\231\149\140" width=2 fg=index:2 bg=rgb:1,2,3
        10 "x" width=1 fg=index:2 bg=rgb:1,2,3
        scrolled="f"
        bottom="s"
        closed terminal
        |}]
  end)
