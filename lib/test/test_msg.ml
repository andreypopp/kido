open Kido

let%expect_test "an envelope serializes with Go's field set: from.session always, empties omitted" =
  let env : Msg.envelope =
    {
      kind = Message;
      id = "x";
      from = { session = ""; name = ""; pane = "%3" };
      reply_to = "";
      text = "";
      run = "";
      output = "";
    }
  in
  print_endline (Yojson.Safe.to_string (Msg.envelope_to_yojson env));
  print_endline
    (Yojson.Safe.to_string
       (Msg.envelope_to_yojson
          {
            env with
            kind = Stream;
            from = { session = "s"; name = "n"; pane = "" };
            reply_to = "a";
            text = "t";
            run = "r";
            output = "o";
          }));
  [%expect
    {|
    {"v":1,"kind":"message","id":"x","from":{"session":"","pane":"%3"},"text":""}
    {"v":1,"kind":"stream","id":"x","from":{"session":"s","name":"n"},"replyTo":"a","text":"t","run":"r","output":"o"}
    |}]

let%expect_test "NewID is non-empty and unique" =
  let a, b = (Msg.new_id (), Msg.new_id ()) in
  Printf.printf "%b %b\n" (String.length a > 0) (not (String.equal a b));
  [%expect {| true true |}]

let%expect_test "Deliver round-trips a message byte for byte over a real unix socket" =
  let path, received = Fixture.start_inbox ~reply:"ok\n" in
  List.iter
    (fun text ->
      match Msg.deliver ~path text with
      | Ok () -> ()
      | Error _ -> print_endline "Deliver failed, want Ok")
    [ "hello there"; "first line\nsecond line\n\nfourth"; "h\xc3\xa9llo unicode \xe2\x9c\xb3" ];
  List.iter print_endline (received ());
  [%expect {|
    hello there
    first line
    second line

    fourth
    héllo unicode ✳
    |}]

let%expect_test "a refused reply is Refused, never Unavailable" =
  let path, _ = Fixture.start_inbox ~reply:"refused\n" in
  (match Msg.deliver ~path "hi" with
  | Error (Refused _) -> print_endline "refused, as expected"
  | Error (Unavailable _) -> print_endline "WRONG: unavailable"
  | Error (Failed _) -> print_endline "WRONG: failed"
  | Ok () -> print_endline "WRONG: ok");
  [%expect {| refused, as expected |}]

let%expect_test "an unrecognised reply is Failed, never Unavailable" =
  let path, _ = Fixture.start_inbox ~reply:"nope\n" in
  (match Msg.deliver ~path "hi" with
  | Error (Failed _) -> print_endline "failed, as expected"
  | Error (Unavailable _) -> print_endline "WRONG: unavailable"
  | Error (Refused _) -> print_endline "WRONG: refused"
  | Ok () -> print_endline "WRONG: ok");
  [%expect {| failed, as expected |}]

let%expect_test
    "a peer that never answers times out as Failed, not Unavailable, and the message was already \
     sent" =
  let path, received = Fixture.start_inbox ~reply:"" in
  let start = Unix.gettimeofday () in
  (match Msg.deliver ~timeout:0.2 ~path "hi" with
  | Error (Failed m) ->
      print_endline "failed, as expected";
      print_endline (if String.mem ~sub:": timed out" m then "timed out" else m)
  | Error (Unavailable _) -> print_endline "WRONG: unavailable"
  | Error (Refused _) -> print_endline "WRONG: refused"
  | Ok () -> print_endline "WRONG: ok");
  Printf.printf "under budget: %b\n" Float.(Unix.gettimeofday () -. start < 1.0);
  print_endline (String.concat ";" (received ()));
  [%expect {|
    failed, as expected
    timed out
    under budget: true
    hi
    |}]

let%expect_test "Deliver reports Unavailable without touching the network" =
  let cases =
    [
      ("empty", "");
      ("missing", Filename.concat (Filename.temp_dir "kido-inbox" "") "nothing-here.sock");
      ("toolong", "/tmp/" ^ String.repeat "x" 200 ^ ".sock");
    ]
  in
  List.iter
    (fun (name, path) ->
      match Msg.deliver ~path "hi" with
      | Error (Unavailable _) -> Printf.printf "%s: unavailable, as expected\n" name
      | Error (Refused _) -> Printf.printf "%s: WRONG refused\n" name
      | Error (Failed _) -> Printf.printf "%s: WRONG failed\n" name
      | Ok () -> Printf.printf "%s: WRONG ok\n" name)
    cases;
  [%expect
    {|
    empty: unavailable, as expected
    missing: unavailable, as expected
    toolong: unavailable, as expected
    |}]

let%expect_test "a stale socket is Unavailable" =
  let dir = Filename.temp_dir "kido-inbox" "" in
  let path = Filename.concat dir "stale.sock" in
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind fd (Unix.ADDR_UNIX path);
  Unix.close fd;
  (match Msg.deliver ~path "hi" with
  | Error (Unavailable _) -> print_endline "unavailable, as expected"
  | _ -> print_endline "WRONG");
  [%expect {| unavailable, as expected |}]

let%expect_test "InboxPath: absolute and pure" =
  let dir = Filename.temp_dir "kido-inbox" "" in
  let got = Result.get_exn (Msg.inbox_path ~dir "pi-123") in
  Printf.printf "%s\n" (if Filename.check_suffix got "/inbox/pi-123.sock" then "suffix ok" else got);
  Printf.printf "absolute: %b\n" (Filename.is_relative got |> not);
  Printf.printf "directory exists: %b\n" (Sys.file_exists (Filename.concat dir "inbox"));
  [%expect {|
    suffix ok
    absolute: true
    directory exists: false
    |}]

let%expect_test "InboxPath rejects a name that would escape or overflow sun_path" =
  let dir = Filename.temp_dir "kido-inbox" "" in
  List.iter
    (fun name ->
      match Msg.inbox_path ~dir name with
      | Ok _ -> Printf.printf "%S: WRONG, want an error\n" name
      | Error _ -> Printf.printf "%S: rejected\n" name)
    [ ""; ".."; "../escape"; "sub/agent"; "a..b" ];
  [%expect
    {|
    "": rejected
    "..": rejected
    "../escape": rejected
    "sub/agent": rejected
    "a..b": rejected
    |}]

let%expect_test "utf_8_prefix drops a partial rune wherever the cut falls inside it" =
  let s = "ab\u{1F389}cd" in
  List.iter
    (fun cut -> Printf.printf "%d: %S\n" cut (Msg.utf_8_prefix s cut))
    [ -1; 0; 3; 4; 5; 6; 8 ];
  [%expect
    {|
    -1: ""
    0: ""
    3: "ab"
    4: "ab"
    5: "ab"
    6: "ab\240\159\142\137"
    8: "ab\240\159\142\137cd"
    |}]

let%expect_test "valid_utf_8 replaces each invalid sequence and keeps the rest" =
  List.iter
    (fun s -> Printf.printf "%S\n" (Msg.valid_utf_8 s))
    [ "ok \u{2603}"; "a\xffb"; "\xff\xfe"; "cut \xe2\x98" ];
  [%expect
    {|
    "ok \226\152\131"
    "a\239\191\189b"
    "\239\191\189\239\191\189"
    "cut \239\191\189"
    |}]
