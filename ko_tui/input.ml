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
  if (not (m.ctrl && m.shift)) || m.alt || m.super || m.hyper || m.meta then None
  else
    match (event.event_type, event.key) with
    | Release, _ -> None
    | _, Char u -> (
        match Uchar.to_int u with
        | 115 | 83 -> Some Toggle_sidebar
        | 101 | 69 -> Some Pager
        | 110 | 78 -> Some New
        | 119 | 87 -> Some Remove
        | 113 | 81 -> Some Detach
        | _ -> None)
    | _, Up -> Some Previous
    | _, Down -> Some Next
    | _ -> None

let key (event : Matrix_input.Key.event) =
  let open Matrix_input.Key in
  let unshifted_codepoint =
    match event.key with
    | Char u -> (
        let c = Uchar.to_int u in
        if c >= 65 && c <= 90 then c + 32
        else
          match Char.chr (min c 255) with
          | '!' -> 49
          | '@' -> 50
          | '#' -> 51
          | '$' -> 52
          | '%' -> 53
          | '^' -> 54
          | '&' -> 55
          | '*' -> 56
          | '(' -> 57
          | ')' -> 48
          | '_' -> 45
          | '+' -> 61
          | '{' -> 91
          | '}' -> 93
          | '|' -> 92
          | ':' -> 59
          | '"' -> 39
          | '<' -> 44
          | '>' -> 46
          | '?' -> 47
          | '~' -> 96
          | _ -> if c < 128 then c else 0)
    | _ -> 0
  in
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
  let shifted =
    match event.key with
    | Char u -> unshifted_codepoint <> 0 && Uchar.to_int u <> unshifted_codepoint
    | _ -> false
  in
  let mods = mods { event.modifier with shift = event.modifier.shift || shifted } in
  {
    Ko_server.Protocol.action =
      (match event.event_type with Release -> 0 | Press -> 1 | Repeat -> 2);
    key;
    mods;
    unshifted_codepoint;
    text = event.associated_text;
    composing = false;
  }

let mouse ~pane_x event =
  let module M = Mosaic.Event.Mouse in
  let button = function M.Left -> 1 | Right -> 2 | Middle -> 3 | Button n -> n in
  let action, button =
    match M.kind event with
    | Down { button = b } -> (0, button b)
    | Up { button = b; _ } -> (1, button b)
    | Drag { button = b; _ } -> (2, button b)
    | Move -> (2, 0)
    | Scroll { direction; _ } -> (0, if M.equal_scroll_direction direction Scroll_up then 4 else 5)
    | _ -> (2, 0)
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
    let%expect_test "Ctrl+Shift commands do not consume ordinary control keys" =
      let encode = key in
      let open Matrix_input in
      let k = Key.of_char ~modifier:{ Modifier.none with ctrl = true; shift = true } 's' in
      assert (Option.is_some (command k));
      assert (Option.is_none (command { k with modifier = { k.modifier with shift = false } }));
      assert (Option.is_none (command { k with event_type = Release }));
      print_endline (Yojson.Safe.to_string (Ko_server.Protocol.yojson_of_key (encode k)));
      [%expect
        {|{"action":1,"key":38,"mods":3,"unshifted_codepoint":115,"text":"s","composing":false}|}]

    let%expect_test "replies together or split across reads are not keys" =
      List.iter
        (fun reads ->
          let p = Matrix_input.Parser.create () in
          let events = ref 0 and responses = ref 0 in
          let on_event _ = incr events and on_response _ = incr responses in
          List.iter
            (fun s ->
              Matrix_input.Parser.feed p (Bytes.of_string s) 0 (String.length s) ~now:0. ~on_event
                ~on_response)
            reads;
          Matrix_input.Parser.drain p ~now:10. ~on_event ~on_response;
          Printf.printf "keys %d replies %d\n" !events !responses)
        [
          [ "\027P>|kitty(0.35.2)\027\\\027[?1u\027[?62;22c\027_Gi=1;OK\027\\" ];
          [ "\027P>|kit"; "ty(0.35.2)\027\\\027[?"; "1u\027[?62;22c\027_Gi=1;OK\027\\" ];
        ];
      [%expect {|
        keys 0 replies 4
        keys 0 replies 4
      |}]
  end)
