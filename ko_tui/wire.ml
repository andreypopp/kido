exception Error of string

type t = {
  fd : Unix.file_descr;
  buf : Bytes.t;
  mutable pos : int;
  mutable len : int;
  write_lock : Mutex.t;
  random : Random.State.t;
  mutable closed : bool;
}

let of_fd fd =
  Unix.setsockopt_int fd Unix.SO_RCVBUF (1 lsl 20);
  {
    fd;
    buf = Bytes.create 65536;
    pos = 0;
    len = 0;
    write_lock = Mutex.create ();
    random = Random.State.make_self_init ();
    closed = false;
  }

let close t =
  if not t.closed then (
    t.closed <- true;
    (try Unix.shutdown t.fd Unix.SHUTDOWN_ALL with Unix.Unix_error _ -> ());
    Unix.close t.fd)

let read t n =
  let out = Bytes.create n in
  let rec go off =
    if off < n then (
      if t.pos = t.len then (
        let readable, _, _ = Unix.select [ t.fd ] [] [] 40. in
        if List.is_empty readable then raise (Unix.Unix_error (Unix.ETIMEDOUT, "read", "ko socket"));
        t.len <- Unix.read t.fd t.buf 0 (Bytes.length t.buf);
        t.pos <- 0;
        if t.len = 0 then raise End_of_file);
      let count = min (n - off) (t.len - t.pos) in
      Bytes.blit t.buf t.pos out off count;
      t.pos <- t.pos + count;
      go (off + count))
  in
  go 0;
  Bytes.unsafe_to_string out

let write t s = Fs.write_all t.fd s

let line t =
  let b = Buffer.create 80 in
  let rec go () =
    let c = (read t 1).[0] in
    if Char.equal c '\n' then
      let s = Buffer.contents b in
      if String.ends_with ~suffix:"\r" s then String.sub s 0 (String.length s - 1) else s
    else (
      if Buffer.length b >= 65536 then raise (Error "HTTP header too long");
      Buffer.add_char b c;
      go ())
  in
  go ()

let headers t =
  let status = line t in
  let rec go fields =
    match line t with
    | "" -> (status, fields)
    | s -> (
        match String.index_opt s ':' with
        | None -> raise (Error "invalid HTTP header")
        | Some i ->
            go
              (( String.lowercase_ascii (String.sub s 0 i),
                 String.trim (String.sub s (i + 1) (String.length s - i - 1)) )
              :: fields))
  in
  go []

let head ?client meth path extra =
  Printf.sprintf "%s %s HTTP/1.1\r\nHost: localhost\r\nKo-Protocol: %s\r\nKo-Vt: %s\r\n%s%s\r\n"
    meth path Ko_server.Config.protocol Ko_server.Config.vt
    (match client with None -> "" | Some c -> "Ko-Client: " ^ c ^ "\r\n")
    extra

let request ~socket ?client ?consume ~meth ~path body =
  let t = of_fd (Ko_server.Socket.connect ~socket ~deadline:(Unix.gettimeofday () +. 5.)) in
  Fun.protect
    ~finally:(fun () -> close t)
    (fun () ->
      write t
        (head ?client meth path
           (Printf.sprintf "Content-Length: %d\r\nConnection: keep-alive\r\n" (String.length body))
        ^ body);
      let status, fields = headers t in
      let b = Buffer.create 4096 in
      let consume =
        if String.starts_with ~prefix:"HTTP/1.1 200 " status then
          Option.value ~default:(Buffer.add_string b) consume
        else Buffer.add_string b
      in
      let rec body_bytes n =
        if n > 0 then (
          let count = min n 65536 in
          consume (read t count);
          body_bytes (n - count))
      in
      (match List.assoc_opt ~eq:String.equal "transfer-encoding" fields with
      | Some "chunked" ->
          let rec chunks () =
            let s = List.hd (String.split_on_char ';' (line t)) in
            let n = int_of_string ("0x" ^ s) in
            if n = 0 then ignore (line t)
            else (
              body_bytes n;
              if not (String.equal (read t 2) "\r\n") then raise (Error "invalid HTTP chunk");
              chunks ())
          in
          chunks ()
      | _ -> (
          match List.assoc_opt ~eq:String.equal "content-length" fields with
          | Some n -> body_bytes (int_of_string n)
          | None -> (
              try
                while true do
                  consume (read t 1)
                done
              with End_of_file -> ())));
      let body = Buffer.contents b in
      if not (String.starts_with ~prefix:"HTTP/1.1 200 " status) then
        raise (Error (status ^ ": " ^ body));
      body)

let upgrade t ?client ~path () =
  let key =
    Base64.encode_exn (String.init 16 (fun _ -> Char.chr (Random.State.int t.random 256)))
  in
  write t
    (head ?client "GET" path
       ("Upgrade: websocket\r\n\
         Connection: Upgrade\r\n\
         Sec-WebSocket-Version: 13\r\n\
         Sec-WebSocket-Key: " ^ key ^ "\r\n"));
  let status, fields = headers t in
  let expected =
    Base64.encode_exn (Ko_server.Sha1.digest (key ^ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
  in
  if
    (not (String.starts_with ~prefix:"HTTP/1.1 101 " status))
    || not
         (Option.exists (String.equal expected)
            (List.assoc_opt ~eq:String.equal "sec-websocket-accept" fields))
  then raise (Error ("WebSocket upgrade failed: " ^ status))

let frame t opcode payload =
  Mutex.protect t.write_lock (fun () ->
      let n = String.length payload in
      let ext = if n < 126 then 0 else if n <= 65535 then 2 else 8 in
      let b = Bytes.create (2 + ext + 4 + n) in
      Bytes.set b 0 (Char.chr (128 lor opcode));
      Bytes.set b 1 (Char.chr (128 lor if ext = 0 then n else if ext = 2 then 126 else 127));
      for i = 0 to ext - 1 do
        Bytes.set b (2 + i) (Char.chr ((n lsr (8 * (ext - 1 - i))) land 255))
      done;
      let mask = String.init 4 (fun _ -> Char.chr (Random.State.int t.random 256)) in
      Bytes.blit_string mask 0 b (2 + ext) 4;
      String.iteri
        (fun i c ->
          Bytes.set b (6 + ext + i) (Char.chr (Char.code c lxor Char.code mask.[i mod 4])))
        payload;
      write t (Bytes.unsafe_to_string b))

let send t json = frame t 1 (Yojson.Safe.to_string json)

let receive t =
  let buffer = ref None in
  let rec go kind =
    let h = read t 2 in
    let op = Char.code h.[0] land 15 and final = Char.code h.[0] land 128 <> 0 in
    let n = Char.code h.[1] land 127 in
    if Char.code h.[1] land 128 <> 0 then raise (Error "masked server frame");
    let n =
      if n < 126 then n
      else
        let s = read t (if n = 126 then 2 else 8) in
        String.fold_left
          (fun n c ->
            if n > max_int lsr 8 then raise (Error "WebSocket frame too large");
            (n lsl 8) lor Char.code c)
          0 s
    in
    if n > 128 lsl 20 then raise (Error "WebSocket frame too large");
    let payload = read t n in
    match op with
    | 8 -> `Close
    | 9 ->
        frame t 10 payload;
        go kind
    | 10 -> go kind
    | 0 | 1 | 2 ->
        let kind = if op = 0 then kind else op in
        let payload =
          if final && Option.is_none !buffer then payload
          else
            let b =
              match !buffer with
              | Some b -> b
              | None ->
                  let b = Buffer.create (String.length payload) in
                  buffer := Some b;
                  b
            in
            Buffer.add_string b payload;
            if final then Buffer.contents b else ""
        in
        if final then if kind = 1 then `Text payload else `Binary payload else go kind
    | _ -> raise (Error "invalid WebSocket opcode")
  in
  try go 0 with End_of_file -> `Close
