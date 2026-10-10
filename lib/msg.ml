let sun_path_max = 103

let inbox_path ~dir name =
  let dir =
    Filename.concat
      (if Filename.is_relative dir then Filename.concat (Sys.getcwd ()) dir else dir)
      "inbox"
  in
  let path = Filename.concat dir (name ^ ".sock") in
  if String.is_empty name then Error "empty name"
  else if String.contains name '/' then
    Error (Printf.sprintf "name %S contains a path separator" name)
  else if String.mem ~sub:".." name then Error (Printf.sprintf "name %S contains %S" name "..")
  else if String.length path > sun_path_max then
    Error
      (Printf.sprintf "socket path is %d bytes, over the %d-byte limit: %s" (String.length path)
         sun_path_max path)
  else Ok path

type kind = Message | Ask | Reply | Notice | Stream | Steer | Interrupt | Stop | Asks

let string_of_kind = function
  | Message -> "message"
  | Ask -> "ask"
  | Reply -> "reply"
  | Notice -> "notice"
  | Stream -> "stream"
  | Steer -> "steer"
  | Interrupt -> "interrupt"
  | Stop -> "stop"
  | Asks -> "asks"

let kind_to_yojson k = `String (string_of_kind k)

type from = {
  session : string;
  name : string; [@default ""]
  pane :
    (Tmux.Pane.id option
    [@to_yojson Tmux_pane.optional_id_to_yojson] [@of_yojson Tmux_pane.optional_id_of_yojson]);
      [@default None]
}
[@@deriving to_yojson]

type envelope = {
  kind : kind;
  id : string;
  from : from;
  reply_to : string; [@key "replyTo"] [@default ""]
  text : string;
  run : string; [@default ""]
  output : string; [@default ""]
}
[@@deriving to_yojson]

let envelope_to_yojson e =
  Yojson.Safe.Util.combine (`Assoc [ ("v", `Int 1) ]) (envelope_to_yojson e)

let max_notice_bytes = 4000

let utf_8_prefix s n =
  let rec boundary n = if n > 0 && Char.code s.[n] land 0xC0 = 0x80 then boundary (n - 1) else n in
  if String.length s <= n then s else String.sub s 0 (boundary (Int.max 0 n))

let valid_utf_8 s =
  let b = Buffer.create (String.length s) in
  let rec go i =
    if i < String.length s then begin
      let d = String.get_utf_8_uchar s i in
      let n = Uchar.utf_decode_length d in
      if Uchar.utf_decode_is_valid d then Buffer.add_substring b s i n
      else Buffer.add_string b "\u{FFFD}";
      go (i + n)
    end
  in
  go 0;
  Buffer.contents b

let new_id () =
  Digest.to_hex (In_channel.with_open_bin "/dev/urandom" (fun ic -> really_input_string ic 16))

type error = Unavailable of string | Refused of string | Failed of string

let string_of_error = function
  | Unavailable why -> "no agent listening on the inbox: " ^ why
  | Refused m | Failed m -> m

exception Timeout

let describe = function Unix.Unix_error (e, _, _) -> Unix.error_message e | _ -> "timed out"

let wait fd ~write deadline =
  let timeout = deadline -. Unix.gettimeofday () in
  if Float.(timeout <= 0.) then raise Timeout;
  let r, w, _ =
    if write then Unix.select [] [ fd ] [] timeout else Unix.select [ fd ] [] [] timeout
  in
  if List.is_empty r && List.is_empty w then raise Timeout

let connect path deadline =
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  (try
     Unix.set_nonblock fd;
     try Unix.connect fd (Unix.ADDR_UNIX path)
     with Unix.Unix_error (Unix.EINPROGRESS, _, _) -> (
       wait fd ~write:true deadline;
       match Unix.getsockopt_error fd with
       | Some err -> raise (Unix.Unix_error (err, "connect", path))
       | None -> ())
   with e ->
     Unix.close fd;
     raise e);
  fd

let write_all fd s deadline =
  let n = String.length s in
  let pos = ref 0 in
  while !pos < n do
    wait fd ~write:true deadline;
    match Unix.write_substring fd s !pos (n - !pos) with
    | w -> pos := !pos + w
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
  done

let read_all fd deadline =
  let buf = Buffer.create 256 in
  let chunk = Bytes.create 65536 in
  let rec loop () =
    wait fd ~write:false deadline;
    match Unix.read fd chunk 0 (Bytes.length chunk) with
    | 0 -> ()
    | n ->
        Buffer.add_subbytes buf chunk 0 n;
        loop ()
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> loop ()
  in
  loop ();
  Buffer.contents buf

let deliver ?(timeout = 2.) ~path text =
  if String.is_empty path then Error (Unavailable "no socket path")
  else
    let deadline = Unix.gettimeofday () +. timeout in
    match connect path deadline with
    | exception ((Timeout | Unix.Unix_error _) as e) ->
        Error (Unavailable (Printf.sprintf "%s: %s" path (describe e)))
    | fd ->
        Fun.protect
          ~finally:(fun () -> try Unix.close fd with Unix.Unix_error _ -> ())
          (fun () ->
            match
              write_all fd text deadline;
              Unix.shutdown fd Unix.SHUTDOWN_SEND;
              read_all fd deadline
            with
            | reply -> (
                match String.trim reply with
                | "ok" -> Ok ()
                | "refused" ->
                    Error
                      (Refused
                         (Printf.sprintf
                            "inbox %s: ask refused: the target already has an ask outstanding to \
                             the asker"
                            path))
                | got ->
                    Error (Failed (Printf.sprintf "inbox %s: answered %S, want \"ok\"" path got)))
            | exception ((Timeout | Unix.Unix_error _) as e) ->
                Error (Failed (Printf.sprintf "inbox %s: %s" path (describe e))))

let live_parent live session =
  Option.to_result
    (Printf.sprintf "no live process holds session %S; the parent is gone, nothing sent" session)
    (List.assoc_opt ~eq:String.equal session live)

let notify ~dir ~parent_session ~from text =
  match live_parent (State.load_live ~dir) parent_session with
  | Error m -> Error (Failed m)
  | Ok (target : State.session) when String.is_empty target.inbox ->
      Error (Unavailable (Printf.sprintf "session %s has no inbox" parent_session))
  | Ok target ->
      deliver ~path:target.inbox
        (Yojson.Safe.to_string
           (envelope_to_yojson
              { kind = Notice; id = new_id (); from; reply_to = ""; text; run = ""; output = "" }))

let%test_module "Tests" =
  (module struct
    let%expect_test
        "an envelope serializes with Go's field set: from.session always, empties omitted" =
      let env : envelope =
        {
          kind = Message;
          id = "x";
          from = { session = ""; name = ""; pane = Tmux.Pane.of_string "%3" };
          reply_to = "";
          text = "";
          run = "";
          output = "";
        }
      in
      print_endline (Yojson.Safe.to_string (envelope_to_yojson env));
      print_endline
        (Yojson.Safe.to_string
           (envelope_to_yojson
              {
                env with
                kind = Stream;
                from = { session = "s"; name = "n"; pane = Tmux.Pane.of_string "" };
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
      let a, b = (new_id (), new_id ()) in
      Printf.printf "%b %b\n" (String.length a > 0) (not (String.equal a b));
      [%expect {| true true |}]

    let%expect_test "Deliver round-trips a message byte for byte over a real unix socket" =
      let path, received = Test_support.start_inbox ~reply:"ok\n" in
      List.iter
        (fun text ->
          match deliver ~path text with
          | Ok () -> ()
          | Error _ -> print_endline "Deliver failed, want Ok")
        [ "hello there"; "first line\nsecond line\n\nfourth"; "h\xc3\xa9llo unicode \xe2\x9c\xb3" ];
      List.iter print_endline (received ());
      [%expect
        {|
    hello there
    first line
    second line

    fourth
    héllo unicode ✳
    |}]

    let%expect_test "a refused reply is Refused, never Unavailable" =
      let path, _ = Test_support.start_inbox ~reply:"refused\n" in
      (match deliver ~path "hi" with
      | Error (Refused _) -> print_endline "refused, as expected"
      | Error (Unavailable _) -> print_endline "WRONG: unavailable"
      | Error (Failed _) -> print_endline "WRONG: failed"
      | Ok () -> print_endline "WRONG: ok");
      [%expect {| refused, as expected |}]

    let%expect_test "an unrecognised reply is Failed, never Unavailable" =
      let path, _ = Test_support.start_inbox ~reply:"nope\n" in
      (match deliver ~path "hi" with
      | Error (Failed _) -> print_endline "failed, as expected"
      | Error (Unavailable _) -> print_endline "WRONG: unavailable"
      | Error (Refused _) -> print_endline "WRONG: refused"
      | Ok () -> print_endline "WRONG: ok");
      [%expect {| failed, as expected |}]

    let%expect_test
        "a peer that never answers times out as Failed, not Unavailable, and the message was \
         already sent" =
      let path, received = Test_support.start_inbox ~reply:"" in
      let start = Unix.gettimeofday () in
      (match deliver ~timeout:0.2 ~path "hi" with
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
          match deliver ~path "hi" with
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
      (match deliver ~path "hi" with
      | Error (Unavailable _) -> print_endline "unavailable, as expected"
      | _ -> print_endline "WRONG");
      [%expect {| unavailable, as expected |}]

    let%expect_test "InboxPath: absolute and pure" =
      let dir = Filename.temp_dir "kido-inbox" "" in
      let got = Result.get_exn (inbox_path ~dir "pi-123") in
      Printf.printf "%s\n"
        (if Filename.check_suffix got "/inbox/pi-123.sock" then "suffix ok" else got);
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
          match inbox_path ~dir name with
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
        (fun cut -> Printf.printf "%d: %S\n" cut (utf_8_prefix s cut))
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
        (fun s -> Printf.printf "%S\n" (valid_utf_8 s))
        [ "ok \u{2603}"; "a\xffb"; "\xff\xfe"; "cut \xe2\x98" ];
      [%expect
        {|
    "ok \226\152\131"
    "a\239\191\189b"
    "\239\191\189\239\191\189"
    "cut \239\191\189"
    |}]
  end)
