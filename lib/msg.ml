type error = Unavailable of string | Failed of string

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
                | got ->
                    Error (Failed (Printf.sprintf "inbox %s: answered %S, want \"ok\"" path got)))
            | exception ((Timeout | Unix.Unix_error _) as e) ->
                Error (Failed (Printf.sprintf "inbox %s: %s" path (describe e))))

let%test_module "Tests" =
  (module struct
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

    let%expect_test "an unrecognised reply is Failed, never Unavailable" =
      let path, _ = Test_support.start_inbox ~reply:"nope\n" in
      (match deliver ~path "hi" with
      | Error (Failed _) -> print_endline "failed, as expected"
      | Error (Unavailable _) -> print_endline "WRONG: unavailable"
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
  end)
