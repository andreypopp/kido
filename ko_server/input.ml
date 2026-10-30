let encode input =
  let b = Buffer.create 64 in
  let num n width =
    if n < 0 || (width < 8 && n >= 1 lsl (8 * width)) then invalid_arg "input value out of range";
    Pane_proc.number b n width
  in
  let kind =
    match input with
    | Protocol.Key key ->
        if key.action > 2 || key.key > Pane_proc.max_key then invalid_arg "invalid key";
        if
          key.unshifted_codepoint > 0x10ffff
          || (key.unshifted_codepoint >= 0xd800 && key.unshifted_codepoint <= 0xdfff)
        then invalid_arg "invalid codepoint";
        num key.action 1;
        num key.key 2;
        num key.mods 2;
        num key.unshifted_codepoint 4;
        Pane_proc.string b key.text;
        num (if key.composing then 1 else 0) 1;
        Pane_proc.Key
    | Mouse mouse ->
        if mouse.action > 2 || mouse.button > 11 then invalid_arg "invalid mouse event";
        num mouse.action 1;
        num mouse.button 1;
        num mouse.col 2;
        num mouse.row 2;
        num mouse.mods 2;
        Mouse
    | Paste paste ->
        Pane_proc.string b paste.text;
        num (if paste.check_safe then 1 else 0) 1;
        Paste
    | Text encoded ->
        (match Base64.decode encoded with
        | Ok text -> Buffer.add_string b text
        | Error (`Msg message) -> invalid_arg message);
        Text
    | Focus focused ->
        num (if focused then 1 else 0) 1;
        Focus
  in
  (kind, Buffer.contents b)

let send pane input reply =
  try
    let kind, body = encode input in
    (match input with
    | Protocol.Paste paste ->
        Pane_proc.paste (Pane.proc pane) body (function
          | Error message -> reply (Error message)
          | Ok (pasted, unsafe) ->
              reply (Ok (Some { Protocol.paste = { id = paste.id; pasted; unsafe } })))
    | _ ->
        if not (Pane_proc.alive (Pane.proc pane)) then reply (Error "pane process ended")
        else (
          Pane_proc.send (Pane.proc pane) kind body;
          reply (Ok None)));
    Ok ()
  with Invalid_argument message -> Error message

let%test_module "Tests" =
  (module struct
    let%expect_test "typed input stays binary" =
      let kind, body = encode (Protocol.Text "AAo=") in
      assert (Pane_proc.equal_kind kind Text);
      Printf.printf "%d %d %d\n" (String.length body) (Char.code body.[0]) (Char.code body.[1]);
      let kind, body = encode (Protocol.Focus true) in
      assert (Pane_proc.equal_kind kind Focus);
      Printf.printf "%d\n" (Char.code body.[0]);
      let kind, body =
        encode
          (Protocol.Key
             {
               action = 1;
               key = 20;
               mods = 2;
               unshifted_codepoint = 97;
               text = "a";
               composing = false;
             })
      in
      assert (Pane_proc.equal_kind kind Key);
      Printf.printf "%d %ld\n" (String.length body) (String.get_int32_le body 5);
      [%expect {|
 2 0 10
 1
 15 97
 |}]
  end)
