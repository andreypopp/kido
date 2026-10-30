module P = Matrix_input.Parser
module E = Matrix_input

let feed reads =
  let p = P.create () in
  let out = ref [] in
  let on_event e = out := Format.asprintf "%a" E.pp e :: !out in
  let on_response r = out := Format.asprintf "response %a" E.Response.pp r :: !out in
  List.iter
    (fun s -> P.feed p (Bytes.of_string s) 0 (String.length s) ~now:0. ~on_event ~on_response)
    reads;
  P.drain p ~now:10. ~on_event ~on_response;
  List.rev !out

let%test_module "Tests" =
  (module struct
    let print reads = List.iter print_endline (feed reads)

    let%expect_test "kitty Ctrl+Shift chords decode as distinct events" =
      List.iter
        (fun s -> print [ s ])
        [
          "\027[115;6u";
          "\027[101;6u";
          "\027[110;6u";
          "\027[119;6u";
          "\027[113;6u";
          "\027[1;6A";
          "\027[1;6B";
          "\027[101;5u";
        ];
      [%expect
        {|
        Key({key=Char(s); modifier={ctrl+shift}; event_type=Press; associated_text="s"})
        Key({key=Char(e); modifier={ctrl+shift}; event_type=Press; associated_text="e"})
        Key({key=Char(n); modifier={ctrl+shift}; event_type=Press; associated_text="n"})
        Key({key=Char(w); modifier={ctrl+shift}; event_type=Press; associated_text="w"})
        Key({key=Char(q); modifier={ctrl+shift}; event_type=Press; associated_text="q"})
        Key({key=Up; modifier={ctrl+shift}; event_type=Press})
        Key({key=Down; modifier={ctrl+shift}; event_type=Press})
        Key({key=Char(e); modifier={ctrl}; event_type=Press; associated_text="e"})
        |}]

    let%expect_test "SGR 1006 wheel" =
      print [ "\027[<64;10;5M"; "\027[<65;10;5M"; "\027[<0;3;4M\027[<0;3;4m" ];
      [%expect
        {|
        Mouse({x=9; y=4; modifiers=none; kind=Scroll(Scroll_up,1)})
        Mouse({x=9; y=4; modifiers=none; kind=Scroll(Scroll_down,1)})
        Mouse({x=2; y=3; modifiers=none; kind=Down(Left)})
        Mouse({x=2; y=3; modifiers=none; kind=Up(Left)})
        |}]

    let%expect_test "XTVERSION, kitty flags and DA1 in one read are no key" =
      print [ "\027P>|kitty(0.35.2)\027\\\027[?1u\027[?62;22c" ];
      [%expect
        {|
        response Capability(Xtversion("kitty(0.35.2)"))
        response Capability(Kitty_keyboard(flags=1))
        response Capability(Device_attributes([62;22]))
        |}]

    let%expect_test "the same replies split across reads are no key" =
      print [ "\027P>|kit"; "ty(0.35.2)\027\\\027[?"; "1u\027[?62;2"; "2c" ];
      [%expect
        {|
        response Capability(Xtversion("kitty(0.35.2)"))
        response Capability(Kitty_keyboard(flags=1))
        response Capability(Device_attributes([62;22]))
        |}]

    let%expect_test "replies between keys, APC _G and focus" =
      print [ "a\027_Gi=1;OK\027\\b\027[I\027[O\027[?997;1n" ];
      [%expect
        {|
        Key({key=Char(a); modifier=none; event_type=Press; associated_text="a"})
        response Capability(Kitty_graphics_reply("i=1;OK"))
        Key({key=Char(b); modifier=none; event_type=Press; associated_text="b"})
        Focus
        Blur
        response Capability(Color_scheme(Dark))
        |}]
  end)
