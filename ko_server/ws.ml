type header = { fin : bool; opcode : int; masked : bool; length : int; size : int }

let extension second = match second land 127 with 126 -> 2 | 127 -> 8 | _ -> 0

let parse s at =
  if String.length s - at < 2 then None
  else
    let first = Char.code s.[at] and second = Char.code s.[at + 1] in
    let extra = extension second in
    let mask = if second land 128 <> 0 then 4 else 0 in
    let size = 2 + extra + mask in
    if String.length s - at < size then None
    else
      let length =
        match extra with
        | 0 -> second land 127
        | 2 -> String.get_uint16_be s (at + 2)
        | _ -> Int64.to_int (String.get_int64_be s (at + 2))
      in
      Some { fin = first land 128 <> 0; opcode = first land 15; masked = mask > 0; length; size }

let encode ?(fin = true) ?declared ?mask ~opcode payload =
  let length = Option.value ~default:(String.length payload) declared in
  let b = Buffer.create (String.length payload + 14) in
  Buffer.add_char b (Char.chr ((if fin then 128 else 0) lor opcode));
  let flag = if Option.is_some mask then 128 else 0 in
  if length < 126 then Buffer.add_char b (Char.chr (flag lor length))
  else if length < 65536 then (
    Buffer.add_char b (Char.chr (flag lor 126));
    Buffer.add_uint16_be b length)
  else (
    Buffer.add_char b (Char.chr (flag lor 127));
    Buffer.add_int64_be b (Int64.of_int length));
  (match mask with
  | None -> Buffer.add_string b payload
  | Some key ->
      Buffer.add_string b key;
      String.iteri
        (fun i c -> Buffer.add_char b (Char.chr (Char.code c lxor Char.code key.[i land 3])))
        payload);
  Buffer.contents b

let%test_module "Tests" =
  (module struct
    let%expect_test "frames of each length class round trip" =
      List.iter
        (fun (n, mask) ->
          let s = encode ?mask ~opcode:2 (String.make n 'x') in
          match parse s 0 with
          | Some h -> Printf.printf "%d: size %d length %d masked %b\n" n h.size h.length h.masked
          | None -> print_endline "short")
        [ (5, None); (200, None); (70000, None); (5, Some "abcd") ];
      [%expect
        {|
        5: size 2 length 5 masked false
        200: size 4 length 200 masked false
        70000: size 10 length 70000 masked false
        5: size 6 length 5 masked true
      |}]
  end)
