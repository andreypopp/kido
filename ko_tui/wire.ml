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

type response = { status : int; reason : string; headers : (string * string) list; body : string }

let headers t =
  let status, reason =
    match String.split_on_char ' ' (line t) with
    | version :: code :: reason when String.equal version "HTTP/1.1" -> (
        match int_of_string_opt code with
        | Some status -> (status, String.concat " " reason)
        | None -> raise (Error "invalid HTTP status"))
    | _ -> raise (Error "invalid HTTP status")
  in
  let rec go fields =
    match line t with
    | "" -> (status, reason, fields)
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
    meth path Ko_server.Protocol.version.protocol Ko_server.Protocol.version.vt
    (match client with
    | None -> ""
    | Some c -> "Ko-Client: " ^ Ko_server.Ids.Client_id.to_string c ^ "\r\n")
    extra

let exchange ~socket ?client ?consume ~meth ~path body =
  let t = of_fd (Launch.connect ~socket ~deadline:(Unix.gettimeofday () +. 5.)) in
  Fun.protect
    ~finally:(fun () -> close t)
    (fun () ->
      write t
        (head ?client meth path
           (Printf.sprintf "Content-Length: %d\r\nConnection: keep-alive\r\n" (String.length body))
        ^ body);
      let status, reason, fields = headers t in
      let b = Buffer.create 4096 in
      let consume =
        if status = 200 then Option.value ~default:(Buffer.add_string b) consume
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
      { status; reason; headers = List.rev fields; body = Buffer.contents b })

let request ~socket ?client ?consume ~route body =
  let meth, path = Ko_server.Protocol.Route.to_request route in
  let response = exchange ~socket ?client ?consume ~meth ~path body in
  if response.status <> 200 then
    raise (Error (Printf.sprintf "%d %s: %s" response.status response.reason response.body));
  response.body

let upgrade t ?client ~route () =
  let meth, path = Ko_server.Protocol.Route.to_request route in
  let key =
    Base64.encode_exn (String.init 16 (fun _ -> Char.chr (Random.State.int t.random 256)))
  in
  write t
    (head ?client meth path
       ("Upgrade: websocket\r\n\
         Connection: Upgrade\r\n\
         Sec-WebSocket-Version: 13\r\n\
         Sec-WebSocket-Key: " ^ key ^ "\r\n"));
  let status, reason, fields = headers t in
  let expected =
    Base64.encode_exn (Ko_server.Sha1.digest (key ^ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
  in
  if
    status <> 101
    || not
         (Option.exists (String.equal expected)
            (List.assoc_opt ~eq:String.equal "sec-websocket-accept" fields))
  then raise (Error (Printf.sprintf "WebSocket upgrade failed: %d %s" status reason))

let frame t opcode payload =
  Mutex.protect t.write_lock (fun () ->
      let mask = String.init 4 (fun _ -> Char.chr (Random.State.int t.random 256)) in
      write t (Ko_server.Ws.encode ~mask ~opcode payload))

let send t json = frame t 1 (Yojson.Basic.to_string json)

let receive t =
  let buffer = ref None in
  let rec go kind =
    let first = read t 2 in
    if Char.code first.[1] land 128 <> 0 then raise (Error "masked server frame");
    let header =
      match
        Ko_server.Ws.parse (first ^ read t (Ko_server.Ws.extension (Char.code first.[1]))) 0
      with
      | Some header -> header
      | None -> raise (Error "invalid WebSocket header")
    in
    let op = header.opcode and final = header.fin and n = header.length in
    if n < 0 || n > 128 lsl 20 then raise (Error "WebSocket frame too large");
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
