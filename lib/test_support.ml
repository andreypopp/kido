let envelope raw =
  match Yojson.Safe.from_string raw with
  | `Assoc f as j
    when List.mem_assoc ~eq:String.equal "v" f && List.mem_assoc ~eq:String.equal "kind" f ->
      Some
        (fun path ->
          match
            List.fold_left
              (fun j k -> Yojson.Safe.Util.member k j)
              j (String.split_on_char '.' path)
          with
          | `String s -> s
          | _ -> "")
  | _ | (exception Yojson.Json_error _) -> None

let dead_pid () =
  let pid = Unix.create_process "true" [| "true" |] Unix.stdin Unix.stdout Unix.stderr in
  ignore (Unix.waitpid [] pid);
  pid

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
