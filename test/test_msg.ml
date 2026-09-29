open Kido

let discriminator_cases =
  [
    ("plain text", "hello there", false);
    ("json array", {|["v","kind"]|}, false);
    ("json scalar", "42", false);
    ("null", "null", false);
    ("true", "true", false);
    ("empty string", "", false);
    ("object missing kind", {|{"v":1,"text":"hi"}|}, false);
    ("object missing v", {|{"kind":"message","text":"hi"}|}, false);
    ("object with neither", {|{"text":"hi","title":"a plan"}|}, false);
    ( "full envelope",
      {|{"v":1,"kind":"message","id":"x","from":{"session":"s1"},"text":"hi"}|},
      true );
    ("v and kind only", {|{"v":1,"kind":"message"}|}, true);
  ]

let%expect_test "Parse agrees with the shared v0/v1 discriminator table" =
  List.iter
    (fun (name, raw, want) ->
      let ok = Option.is_some (Msg.parse raw) in
      Printf.printf "%-24s %b %s\n" name ok (if Bool.equal ok want then "ok" else "MISMATCH"))
    discriminator_cases;
  [%expect
    {|
    plain text               false ok
    json array               false ok
    json scalar              false ok
    null                     false ok
    true                     false ok
    empty string             false ok
    object missing kind      false ok
    object missing v         false ok
    object with neither      false ok
    full envelope            true ok
    v and kind only          true ok
    |}]

let%expect_test "Parse fills every field of a full envelope" =
  let raw =
    {|{"v":1,"kind":"reply","id":"abc","replyTo":"xyz","from":{"session":"s1","name":"worker-2","pane":"%18"},"text":"42"}|}
  in
  (match Msg.parse raw with
  | None -> print_endline "not an envelope"
  | Some (env : Msg.envelope) ->
      Printf.printf "v=%d kind=%s id=%s replyTo=%s from=(%s,%s,%s) text=%s\n" env.v
        (Msg.string_of_kind env.kind) env.id env.reply_to env.from.session env.from.name
        env.from.pane env.text);
  [%expect {| v=1 kind=reply id=abc replyTo=xyz from=(s1,worker-2,%18) text=42 |}]

let%expect_test "an unknown kind round-trips as itself" =
  print_endline (Msg.string_of_kind (Msg.kind_of_string "wat"));
  [%expect {| wat |}]

let%expect_test "NewID is non-empty and unique" =
  let a, b = (Msg.new_id (), Msg.new_id ()) in
  Printf.printf "%b %b\n" (String.length a > 0) (not (String.equal a b));
  [%expect {| true true |}]

(* A fake agent inbox: accepts one connection at a time, reads it to EOF,
   answers with [reply] (empty meaning "never answer"), and records what
   arrived. Stands in for the socket pi's extension listens on. *)
let start_inbox ~reply =
  let dir = Filename.temp_dir "kido-inbox" "" in
  let path = Filename.concat dir "inbox.sock" in
  let listener = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind listener (Unix.ADDR_UNIX path);
  Unix.listen listener 4;
  let received = ref [] in
  let mu = Mutex.create () in
  let serve conn =
    let buf = Buffer.create 256 in
    let chunk = Bytes.create 4096 in
    let rec read_loop () =
      match Unix.read conn chunk 0 4096 with
      | 0 -> ()
      | n ->
          Buffer.add_subbytes buf chunk 0 n;
          read_loop ()
      | exception _ -> ()
    in
    read_loop ();
    Mutex.lock mu;
    received := Buffer.contents buf :: !received;
    Mutex.unlock mu;
    if String.is_empty reply then
      ignore
        (Thread.create
           (fun () ->
             Thread.delay 10.;
             try Unix.close conn with _ -> ())
           ())
    else begin
      (try ignore (Unix.write_substring conn reply 0 (String.length reply)) with _ -> ());
      try Unix.close conn with _ -> ()
    end
  in
  let rec accept_loop () =
    match Unix.accept listener with
    | conn, _ ->
        serve conn;
        accept_loop ()
    | exception _ -> ()
  in
  ignore (Thread.create accept_loop ());
  ( path,
    fun () ->
      Mutex.lock mu;
      let r = List.rev !received in
      Mutex.unlock mu;
      r )

let%expect_test "Deliver round-trips a message byte for byte over a real unix socket" =
  let path, received = start_inbox ~reply:"ok\n" in
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
  let path, _ = start_inbox ~reply:"refused\n" in
  (match Msg.deliver ~path "hi" with
  | Error (Refused _) -> print_endline "refused, as expected"
  | Error (Unavailable _) -> print_endline "WRONG: unavailable"
  | Error (Failed _) -> print_endline "WRONG: failed"
  | Ok () -> print_endline "WRONG: ok");
  [%expect {| refused, as expected |}]

let%expect_test "an unrecognised reply is Failed, never Unavailable" =
  let path, _ = start_inbox ~reply:"nope\n" in
  (match Msg.deliver ~path "hi" with
  | Error (Failed _) -> print_endline "failed, as expected"
  | Error (Unavailable _) -> print_endline "WRONG: unavailable"
  | Error (Refused _) -> print_endline "WRONG: refused"
  | Ok () -> print_endline "WRONG: ok");
  [%expect {| failed, as expected |}]

let%expect_test
    "a peer that never answers times out as Failed, not Unavailable, and the message was already \
     sent" =
  let saved = !Msg.inbox_timeout in
  Msg.inbox_timeout := 0.2;
  let path, received = start_inbox ~reply:"" in
  let start = Unix.gettimeofday () in
  (match Msg.deliver ~path "hi" with
  | Error (Failed _) -> print_endline "failed, as expected"
  | Error (Unavailable _) -> print_endline "WRONG: unavailable"
  | Error (Refused _) -> print_endline "WRONG: refused"
  | Ok () -> print_endline "WRONG: ok");
  Printf.printf "under budget: %b\n" Float.(Unix.gettimeofday () -. start < 1.0);
  Msg.inbox_timeout := saved;
  print_endline (String.concat ";" (received ()));
  [%expect {|
    failed, as expected
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

let%expect_test "InboxPath: absolute, mode 0700, and dialable" =
  let dir = Filename.temp_dir "kido-inbox" "" in
  let got = Msg.inbox_path ~dir "pi-123" in
  Printf.printf "%s\n" (if Filename.check_suffix got "/inbox/pi-123.sock" then "suffix ok" else got);
  Printf.printf "absolute: %b\n" (Filename.is_relative got |> not);
  let st = Unix.stat (Filename.concat dir "inbox") in
  Printf.printf "dir mode: %o\n" (st.st_perm land 0o777);
  let ln = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind ln (Unix.ADDR_UNIX got);
  Unix.close ln;
  [%expect {|
    suffix ok
    absolute: true
    dir mode: 700
    |}]

let%expect_test "InboxPath rejects a name that would escape or overflow sun_path" =
  let dir = Filename.temp_dir "kido-inbox" "" in
  List.iter
    (fun name ->
      match Msg.inbox_path ~dir name with
      | (_ : string) -> Printf.printf "%S: WRONG, want an error\n" name
      | exception Failure _ -> Printf.printf "%S: rejected\n" name)
    [ ""; ".."; "../escape"; "sub/agent"; "a..b" ];
  [%expect
    {|
    "": rejected
    "..": rejected
    "../escape": rejected
    "sub/agent": rejected
    "a..b": rejected
    |}]
