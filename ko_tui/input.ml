let mods (m : Matrix_input.Modifier.t) =
  (if m.shift then 1 else 0)
  lor (if m.ctrl then 2 else 0)
  lor (if m.alt || m.meta then 4 else 0)
  lor (if m.super then 8 else 0)
  lor (if m.caps_lock then 16 else 0)
  lor if m.num_lock then 32 else 0

type command = Toggle_sidebar | Pager | New | Remove | Previous | Next | Detach

let command (event : Matrix_input.Key.event) =
  let m = event.modifier in
  if (not m.ctrl) || m.alt || m.super || m.hyper || m.meta then None
  else
    match (event.event_type, event.key) with
    | Release, _ -> None
    | _, Char u when (not m.shift) && Uchar.to_int u = 100 -> Some Remove
    | _ when not m.shift -> None
    | _, Char u -> (
        match Uchar.to_int u with
        | 115 | 83 -> Some Toggle_sidebar
        | 101 | 69 -> Some Pager
        | 110 | 78 -> Some New
        | 113 | 81 -> Some Detach
        | _ -> None)
    | _, Up -> Some Previous
    | _, Down -> Some Next
    | _ -> None

let us_pairs = "1!2@3#4$5%6^7&8*9(0)-_=+[{]}\\|;:'\",<.>/?`~"

let flip ~up c =
  let ascii = if up then c >= 97 && c <= 122 else c >= 65 && c <= 90 in
  let latin = if up then c >= 0xe0 && c <= 0xfe else c >= 0xc0 && c <= 0xde in
  if ascii || (latin && c <> 0xd7 && c <> 0xf7) then if up then c - 32 else c + 32
  else if c > 127 then c
  else
    match String.index_opt us_pairs (Char.chr c) with
    | Some i when i land 1 = if up then 0 else 1 -> Char.code us_pairs.[if up then i + 1 else i - 1]
    | _ -> c

let utf8 c =
  let b = Buffer.create 4 in
  Buffer.add_utf_8_uchar b (Uchar.of_int c);
  Buffer.contents b

let key (event : Matrix_input.Key.event) =
  let open Matrix_input.Key in
  let typed = match event.key with Char u -> Uchar.to_int u | _ -> 0 in
  let unshifted_codepoint = flip ~up:false typed in
  let key =
    match event.key with
    | Char _ -> (
        let c = unshifted_codepoint in
        if c >= 97 && c <= 122 then 20 + c - 97
        else if c >= 65 && c <= 90 then 20 + c - 65
        else if c >= 48 && c <= 57 then 6 + c - 48
        else
          match c with
          | 96 -> 1
          | 92 -> 2
          | 91 -> 3
          | 93 -> 4
          | 44 -> 5
          | 61 -> 16
          | 45 -> 46
          | 46 -> 47
          | 39 -> 48
          | 59 -> 49
          | 47 -> 50
          | 32 -> 63
          | _ -> 0)
    | Backspace -> 53
    | Enter | Line_feed -> 58
    | Tab -> 64
    | Delete -> 68
    | End -> 69
    | Home -> 71
    | Insert -> 72
    | Page_down -> 73
    | Page_up -> 74
    | Down -> 75
    | Left -> 76
    | Right -> 77
    | Up -> 78
    | Escape -> 120
    | F n when n >= 1 && n <= 25 -> 120 + n
    | Alt_left -> 51
    | Alt_right -> 52
    | Caps_lock -> 54
    | Menu -> 55
    | Ctrl_left -> 56
    | Ctrl_right -> 57
    | Super_left | Meta_left -> 59
    | Super_right | Meta_right -> 60
    | Shift_left -> 61
    | Shift_right -> 62
    | Num_lock -> 79
    | KP_0 -> 80
    | KP_1 -> 81
    | KP_2 -> 82
    | KP_3 -> 83
    | KP_4 -> 84
    | KP_5 -> 85
    | KP_6 -> 86
    | KP_7 -> 87
    | KP_8 -> 88
    | KP_9 -> 89
    | KP_add -> 90
    | KP_decimal -> 95
    | KP_divide -> 96
    | KP_enter -> 97
    | KP_equal -> 98
    | KP_multiply -> 104
    | KP_subtract -> 107
    | KP_separator -> 108
    | KP_up -> 109
    | KP_down -> 110
    | KP_right -> 111
    | KP_left -> 112
    | KP_begin -> 113
    | KP_home -> 114
    | KP_end -> 115
    | KP_insert -> 116
    | KP_delete -> 117
    | KP_page_up -> 118
    | KP_page_down -> 119
    | Print_screen -> 148
    | Scroll_lock -> 149
    | Pause -> 150
    | Media_play_pause -> 162
    | Media_stop -> 164
    | Media_next -> 165
    | Media_prev -> 166
    | Volume_down -> 169
    | Volume_mute -> 170
    | Volume_up -> 171
    | _ -> 0
  in
  let m = event.modifier in
  let mods = mods { m with shift = m.shift || typed <> unshifted_codepoint } in
  let text =
    match event.key with
    | Char _
      when m.shift && typed = unshifted_codepoint && Option.is_none event.shifted_key
           && (not (m.ctrl || m.super || m.hyper))
           && String.equal event.associated_text (utf8 typed) ->
        utf8 (flip ~up:true typed)
    | _ -> event.associated_text
  in
  {
    Ko_server.Protocol.action =
      (match event.event_type with
      | Release -> Key_release
      | Press -> Key_press
      | Repeat -> Key_repeat);
    key;
    mods;
    unshifted_codepoint;
    text;
    composing = false;
  }

let mouse ~pane_x event =
  let module M = Mosaic.Event.Mouse in
  let button : _ -> Ko_server.Protocol.mouse_button = function
    | M.Left -> Button_left
    | Right -> Button_right
    | Middle -> Button_middle
    | Button 4 -> Button_four
    | Button 5 -> Button_five
    | Button 6 -> Button_six
    | Button 7 -> Button_seven
    | Button 8 -> Button_eight
    | Button 9 -> Button_nine
    | Button 10 -> Button_ten
    | Button 11 -> Button_eleven
    | Button _ -> Button_unknown
  in
  let action, button =
    match M.kind event with
    | Down { button = b } -> (Ko_server.Protocol.Mouse_press, button b)
    | Up { button = b; _ } -> (Mouse_release, button b)
    | Drag { button = b; _ } -> (Mouse_motion, button b)
    | Move -> (Mouse_motion, Button_unknown)
    | Scroll { direction; _ } ->
        ( Mouse_press,
          if M.equal_scroll_direction direction Scroll_up then Button_four else Button_five )
    | _ -> (Mouse_motion, Button_unknown)
  in
  {
    Ko_server.Protocol.action;
    button;
    col = M.x event - pane_x;
    row = M.y event;
    mods = mods (M.modifiers event);
  }

let%test_module "Tests" =
  (module struct
    let%expect_test "Ctrl+Shift commands do not consume Ctrl keys" =
      let encode = key in
      let open Matrix_input in
      let k = Key.of_char ~modifier:{ Modifier.none with ctrl = true; shift = true } 's' in
      assert (Option.is_some (command k));
      assert (Option.is_none (command { k with modifier = { k.modifier with shift = false } }));
      assert (Option.is_none (command { k with event_type = Release }));
      print_endline
        (Yojson.Basic.to_string (Ko_server.Protocol.view_message_to_json (Input (Key (encode k)))));
      [%expect
        {| ["input",["key",{"action":"press","key":38,"mods":3,"unshifted_codepoint":115,"text":"s","composing":false}]] |}]

    let parse reads =
      let p = Matrix_input.Parser.create () in
      let events = ref [] and responses = ref 0 in
      let on_event e = events := e :: !events and on_response _ = incr responses in
      List.iter
        (fun s ->
          Matrix_input.Parser.feed p (Bytes.of_string s) 0 (String.length s) ~now:0. ~on_event
            ~on_response)
        reads;
      Matrix_input.Parser.drain p ~now:10. ~on_event ~on_response;
      (List.rev !events, !responses)

    let%expect_test "shifted printable keys carry their text" =
      List.iter
        (fun s ->
          List.iter
            (function
              | Matrix_input.Key k ->
                  Printf.printf "%S %s\n" s
                    (Yojson.Basic.to_string
                       (Ko_server.Protocol.view_message_to_json (Input (Key (key k)))))
              | _ -> ())
            (fst (parse [ s ])))
        [
          "A";
          "!";
          "@";
          "\xc3\x89";
          "\027[97;2u";
          "\027[97;2;65u";
          "\027[49;2u";
          "\027[49:33;2u";
          "\027[233:201;2u";
          "\027[233:201;2;201u";
          "\027[97;1:3u";
          "\027[97;2;937u";
          "\027[97;4u";
          "\027[97;6u";
          "\027[32;2u";
          "\027[13;2u";
        ];
      [%expect
        {|
        "A" ["input",["key",{"action":"press","key":20,"mods":1,"unshifted_codepoint":97,"text":"A","composing":false}]]
        "!" ["input",["key",{"action":"press","key":7,"mods":1,"unshifted_codepoint":49,"text":"!","composing":false}]]
        "@" ["input",["key",{"action":"press","key":8,"mods":1,"unshifted_codepoint":50,"text":"@","composing":false}]]
        "\195\137" ["input",["key",{"action":"press","key":0,"mods":1,"unshifted_codepoint":233,"text":"É","composing":false}]]
        "\027[97;2u" ["input",["key",{"action":"press","key":20,"mods":1,"unshifted_codepoint":97,"text":"A","composing":false}]]
        "\027[97;2;65u" ["input",["key",{"action":"press","key":20,"mods":1,"unshifted_codepoint":97,"text":"A","composing":false}]]
        "\027[49;2u" ["input",["key",{"action":"press","key":7,"mods":1,"unshifted_codepoint":49,"text":"!","composing":false}]]
        "\027[49:33;2u" ["input",["key",{"action":"press","key":7,"mods":1,"unshifted_codepoint":49,"text":"!","composing":false}]]
        "\027[233:201;2u" ["input",["key",{"action":"press","key":0,"mods":1,"unshifted_codepoint":233,"text":"É","composing":false}]]
        "\027[233:201;2;201u" ["input",["key",{"action":"press","key":0,"mods":1,"unshifted_codepoint":233,"text":"É","composing":false}]]
        "\027[97;1:3u" ["input",["key",{"action":"release","key":20,"mods":0,"unshifted_codepoint":97,"text":"a","composing":false}]]
        "\027[97;2;937u" ["input",["key",{"action":"press","key":20,"mods":1,"unshifted_codepoint":97,"text":"Ω","composing":false}]]
        "\027[97;4u" ["input",["key",{"action":"press","key":20,"mods":5,"unshifted_codepoint":97,"text":"A","composing":false}]]
        "\027[97;6u" ["input",["key",{"action":"press","key":20,"mods":3,"unshifted_codepoint":97,"text":"a","composing":false}]]
        "\027[32;2u" ["input",["key",{"action":"press","key":63,"mods":1,"unshifted_codepoint":32,"text":" ","composing":false}]]
        "\027[13;2u" ["input",["key",{"action":"press","key":58,"mods":1,"unshifted_codepoint":0,"text":"","composing":false}]]
        |}]

    let%expect_test "Ctrl+D, legacy or CSI u, is Remove; Ctrl+Shift+W is no command" =
      List.iter
        (fun s ->
          List.iter
            (function
              | Matrix_input.Key k ->
                  print_endline (match command k with Some Remove -> "remove" | _ -> "none")
              | _ -> ())
            (fst (parse [ s ])))
        [ "\004"; "\027[100;5u"; "\027[119;6u" ];
      [%expect {|
        remove
        remove
        none
      |}]

    let%expect_test "replies together or split across reads are not keys" =
      List.iter
        (fun reads ->
          let events, responses = parse reads in
          Printf.printf "keys %d replies %d\n" (List.length events) responses)
        [
          [ "\027P>|kitty(0.35.2)\027\\\027[?1u\027[?62;22c\027_Gi=1;OK\027\\" ];
          [ "\027P>|kit"; "ty(0.35.2)\027\\\027[?"; "1u\027[?62;22c\027_Gi=1;OK\027\\" ];
        ];
      [%expect {|
        keys 0 replies 4
        keys 0 replies 4
      |}]
  end)
