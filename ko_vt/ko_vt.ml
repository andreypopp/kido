type t
type format = Plain | Vt

external create :
  cols:int ->
  rows:int ->
  scrollback_max_bytes:int ->
  apc_max_bytes:int ->
  kitty_image_storage_limit:int ->
  continuation_max_bytes:int ->
  t = "ko_vt_create_bytecode" "ko_vt_create"

external write : t -> string -> unit = "ko_vt_write"
external resize : t -> cols:int -> rows:int -> unit = "ko_vt_resize"
external dump : t -> format -> string = "ko_vt_dump"
external snapshot : t -> screen:bool -> images:bool -> string = "ko_vt_snapshot"
external decode : (int -> string) -> full:bool -> t = "ko_vt_decode"
external cursor : t -> int * int * bool = "ko_vt_cursor"
external mode : t -> int -> bool = "ko_vt_mode"
external total_rows : t -> int = "ko_vt_total_rows"

let%test_module "Tests" =
  (module struct
    let create ~cols ~rows =
      create ~cols ~rows ~scrollback_max_bytes:(32 * 1024 * 1024) ~apc_max_bytes:(65 * 1024 * 1024)
        ~kitty_image_storage_limit:10_000_000 ~continuation_max_bytes:(65 * 1024 * 1024)

    let reader ?(chunk = max_int) bytes =
      let offset = ref 0 in
      fun capacity ->
        let len = min chunk (min capacity (String.length bytes - !offset)) in
        let piece = String.sub bytes !offset len in
        offset := !offset + len;
        piece

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
        Printf.printf "%s: %s\n" label
          (String.concat " " (List.map string_of_int (tags bytes)))
      in
      print_tags "all" (snapshot server ~screen:false ~images:true);
      let filtered = snapshot server ~screen:false ~images:false in
      print_tags "no images" filtered;
      print_tags "screen" (snapshot server ~screen:true ~images:true);
      let restored = decode ~full:true (reader ~chunk:7 filtered) in
      Printf.printf "server_sync=%b mirror_sync=%b\n" (mode server 2026) (mode restored 2026);
      write server "\027[?2026l";
      Printf.printf "equal after server ends sync=%b\n" (String.equal (dump server Vt) (dump restored Vt));
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
          let screen = decode ~full:false (reader (snapshot server ~screen:true ~images:false)) in
          let full = decode ~full:true (reader (snapshot server ~screen:false ~images:false)) in
          List.iter (fun t -> write t after) [ server; screen; full ];
          let same t = String.equal (dump server Vt) (dump t Vt) in
          Printf.printf "%s: screen=%b full=%b plain=%b\n" label (same screen) (same full)
            (String.equal (dump server Plain) (dump screen Plain) && String.equal (dump server Plain) (dump full Plain)))
        [
          ("open hyperlink", "\027]8;;https://example.org\027\\ab", "cd\027]8;;\027\\ ef");
          ("pen", "\027[1;31mab", "cd");
          ("pending wrap", String.make 30 'x', "y");
          ("charset", "\027(0ab", "qq");
          ("inside OSC 8 uri", "\027]8;;file:///tmp/1", "06\027\\/tmp/106\027]8;;\027\\ ef");
          ("alternate screen", "primary\r\n\027[?1049halt", "\027[?1049l");
          ("OSC 8 rows scrolled after decode", osc8 0, String.concat "" (List.init 8 (fun i -> osc8 (i + 1))));
        ];
      [%expect {|
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
            decode ~full:false (reader ~chunk:7 (snapshot server ~screen:true ~images:false))
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
  end)
