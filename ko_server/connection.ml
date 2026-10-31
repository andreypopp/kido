external writev : Unix.file_descr -> bytes -> int -> Luv.Buffer.t -> int -> int -> int
  = "ko_writev_bytecode" "ko_writev"
[@@noalloc]

external write_strings : Unix.file_descr -> string array -> int -> int -> int = "ko_write_strings"
[@@noalloc]

type t = {
  stream : Luv.Pipe.t;
  fd : Unix.file_descr;
  poll : Luv.Poll.t;
  mutable runtime : Gluten.Server.t option;
  mutable closed : bool;
  mutable waiting : bool;
  pending : string Queue.t;
  mutable sent : int;
  headers : bytes;
  strings : string array;
  mutable websocket : bool;
  mutable ready : bool;
  mutable yielded : bool;
  mutable on_text : string -> unit;
  mutable on_close : unit -> unit;
  on_dispose : t -> unit;
  mutable on_writable : unit -> unit;
  read_buf : Bigstringaf.t;
  mutable read_len : int;
  mutable read_pos : int;
  mutable read_progress : bool;
  fragments : Buffer.t;
  mutable last_activity : float;
  mutable ping : float option;
}

let runtime t = Option.get t.runtime
let max_message = 1 lsl 20

let close t =
  if not t.closed then begin
    t.closed <- true;
    Luv.Handle.close t.poll (fun () -> Unix.close t.fd);
    Luv.Handle.close t.stream ignore;
    t.on_close ();
    t.on_dispose t
  end

let when_writable t resume =
  if (not t.closed) && not t.waiting then begin
    t.waiting <- true;
    Luv.Poll.start t.poll [ `WRITABLE ] (fun result ->
        ignore (Luv.Poll.stop t.poll);
        t.waiting <- false;
        match result with Error _ -> close t | Ok _ -> resume ())
  end

let rec wait t =
  when_writable t (fun () ->
      flush t;
      if (not t.closed) && not t.waiting then t.on_writable ())

and flush t =
  if (not t.closed) && not (Queue.is_empty t.pending) then begin
    let rec fill i seq =
      if i = Array.length t.strings then i
      else
        match seq () with
        | Seq.Nil -> i
        | Seq.Cons (s, rest) ->
            t.strings.(i) <- s;
            fill (i + 1) rest
    in
    let count = fill 0 (Queue.to_seq t.pending) in
    let n = write_strings t.fd t.strings count t.sent in
    Array.fill t.strings 0 count "";
    if n < 0 then close t
    else if n = 0 then wait t
    else begin
      let left = ref (n + t.sent) in
      while
        match Queue.peek_opt t.pending with Some s -> !left >= String.length s | None -> false
      do
        let s = Queue.take t.pending in
        left := !left - String.length s
      done;
      t.sent <- !left;
      flush t
    end
  end

let header bytes opcode len =
  Bytes.set bytes 0 (Char.chr (128 lor opcode));
  if len < 126 then (
    Bytes.set bytes 1 (Char.chr len);
    2)
  else if len < 65536 then (
    Bytes.set bytes 1 '\126';
    Bytes.set_uint16_be bytes 2 len;
    4)
  else (
    Bytes.set bytes 1 '\127';
    Bytes.set_int64_be bytes 2 (Int64.of_int len);
    10)

let send t opcode text =
  if not t.closed then
    if String.length text > max_message then close t
    else begin
      let len = header t.headers opcode (String.length text) in
      Queue.add (Bytes.sub_string t.headers 0 len) t.pending;
      Queue.add text t.pending;
      if t.ready then flush t
    end

let json t value = send t 1 (Yojson.Basic.to_string value)

let reject t kind =
  if t.ready && (not t.waiting) && Queue.is_empty t.pending then
    send t 8 ("\003\240" ^ Jsonkit.Of_json.string (Protocol.error_kind_to_json kind));
  close t

let is_closed t = t.closed
let available t = t.ready && (not t.closed) && (not t.waiting) && Queue.is_empty t.pending
let waiting t = t.waiting || not (Queue.is_empty t.pending)

type written = Accepted | Queued | Blocked | Closed

let record_header bytes ~kind ~offset ~len =
  let at = header bytes 2 (len + Protocol.Record.header_size) in
  Protocol.Record.encode_header bytes at kind ~offset;
  at + Protocol.Record.header_size

let record t ~queue ~kind ~offset ring ~at ~len =
  if t.closed then Closed
  else begin
    let h = record_header t.headers ~kind ~offset ~len in
    let n = if available t then writev t.fd t.headers h ring at len else 0 in
    if n < 0 then (
      close t;
      Closed)
    else if n = h + len then Accepted
    else if n > 0 || queue then begin
      if n < h then Queue.add (Bytes.sub_string t.headers n (h - n)) t.pending;
      let skip = max 0 (n - h) in
      if skip < len then
        Queue.add (Bigstringaf.substring ring ~off:(at + skip) ~len:(len - skip)) t.pending;
      if t.ready then wait t;
      Queued
    end
    else (
      if t.ready then wait t;
      Blocked)
  end

let rec write_runtime t =
  if (not t.closed) && not t.yielded then
    match Gluten.Server.next_write_operation (runtime t) with
    | `Write iovecs ->
        let wrote = ref 0 and blocked = ref false in
        List.iter
          (fun { Faraday.buffer; off; len } ->
            if (not !blocked) && not t.closed then
              try
                let text = Bigstringaf.substring buffer ~off ~len in
                let n = Unix.single_write_substring t.fd text 0 len in
                wrote := !wrote + n;
                if n < len then blocked := true
              with
              | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> blocked := true
              | Unix.Unix_error (Unix.EINTR, _, _) -> blocked := true
              | Unix.Unix_error _ -> close t)
          iovecs;
        if t.closed then Gluten.Server.report_write_result (runtime t) `Closed
        else begin
          Gluten.Server.report_write_result (runtime t) (`Ok !wrote);
          if !blocked then when_writable t (fun () -> write_runtime t) else write_runtime t
        end
    | `Yield ->
        if t.websocket then begin
          t.ready <- true;
          flush t;
          t.on_writable ()
        end;
        t.yielded <- true;
        Gluten.Server.yield_writer (runtime t) (fun () ->
            t.yielded <- false;
            write_runtime t)
    | `Close _ -> close t

let rec consume t =
  if not t.closed then begin
    t.read_progress <- false;
    match Gluten.Server.next_read_operation (runtime t) with
    | `Read ->
        let n =
          if t.read_len = t.read_pos then 0
          else
            Gluten.Server.read (runtime t) t.read_buf ~off:t.read_pos ~len:(t.read_len - t.read_pos)
        in
        t.read_pos <- t.read_pos + n;
        if t.read_pos = t.read_len then (
          t.read_pos <- 0;
          t.read_len <- 0);
        if n > 0 || t.read_progress then consume t
    | `Yield -> Gluten.Server.yield_reader (runtime t) (fun () -> consume t)
    | `Close -> close t
  end

let upgrade t reqd upgrade ~on_text ~on_close ~on_writable =
  t.on_text <- on_text;
  t.on_close <- on_close;
  t.on_writable <- on_writable;
  Httpun_ws.Handshake.respond_with_upgrade ~sha1:Sha1.digest reqd (fun () ->
      t.websocket <- true;
      upgrade
        (Gluten.make
           (module Httpun_ws.Server_connection)
           (Httpun_ws.Server_connection.create_websocket (fun _wsd ->
                let frame ~opcode ~is_fin ~len payload =
                  if len > max_message then close t
                  else begin
                    let text = Buffer.create 64 in
                    let rec read () =
                      Httpun_ws.Payload.schedule_read payload
                        ~on_read:(fun bs ~off ~len ->
                          if Buffer.length text + len > max_message then close t
                          else (
                            Buffer.add_string text (Bigstringaf.substring bs ~off ~len);
                            read ()))
                        ~on_eof:(fun () ->
                          (* httpun-ws can complete queued frames in next_read_operation without reading bytes. *)
                          t.read_progress <- true;
                          t.last_activity <- Unix.gettimeofday ();
                          let s = Buffer.contents text in
                          match opcode with
                          | `Text | `Continuation ->
                              if Buffer.length t.fragments + String.length s > max_message then
                                close t
                              else begin
                                Buffer.add_string t.fragments s;
                                if is_fin then begin
                                  let message = Buffer.contents t.fragments in
                                  Buffer.clear t.fragments;

                                  t.on_text message
                                end
                              end
                          | `Connection_close -> close t
                          | `Ping -> send t 10 s
                          | `Pong -> t.ping <- None
                          | _ -> close t)
                    in
                    read ()
                  end
                in
                { Httpun_ws.Websocket_connection.frame; eof = (fun ?error:_ () -> close t) }))))

let create stream ~on_dispose =
  let descriptor =
    Unix.dup ~cloexec:true
      (match Uv.fd stream with
      | Ok fd -> fd
      | Error message -> raise (Unix.Unix_error (Unix.EIO, message, "")))
  in
  Unix.set_nonblock descriptor;
  let t =
    {
      stream;
      fd = descriptor;
      poll = Uv.ok (Luv.Poll.init (Obj.magic descriptor));
      runtime = None;
      closed = false;
      waiting = false;
      pending = Queue.create ();
      headers = Bytes.create 20;
      strings = Array.make 64 "";
      on_dispose;
      sent = 0;
      websocket = false;
      ready = false;
      yielded = false;
      on_text = ignore;
      on_close = ignore;
      on_writable = ignore;
      read_buf = Bigstringaf.create 16384;
      read_len = 0;
      read_pos = 0;
      read_progress = false;
      fragments = Buffer.create 64;
      last_activity = Unix.gettimeofday ();
      ping = None;
    }
  in
  t

let writer fd =
  let stream = Uv.ok (Luv.Pipe.init ()) in
  Uv.ok (Luv.Pipe.open_ stream (Uv.file fd));
  let t = create stream ~on_dispose:ignore in
  t.ready <- true;
  t.websocket <- true;
  t

let accept stream ~on_dispose handler =
  let t = create stream ~on_dispose in
  t.runtime <-
    Some
      (Gluten.Server.create_upgradable
         ~protocol:(module Httpun.Server_connection)
         ~create:(fun h -> Httpun.Server_connection.create h)
         (handler t));
  Luv.Stream.read_start stream
    ~allocate:(fun _ ->
      if t.read_pos > 0 && Bigstringaf.length t.read_buf - t.read_len < 4096 then (
        Bigstringaf.blit t.read_buf ~src_off:t.read_pos t.read_buf ~dst_off:0
          ~len:(t.read_len - t.read_pos);
        t.read_len <- t.read_len - t.read_pos;
        t.read_pos <- 0);
      Bigstringaf.sub t.read_buf ~off:t.read_len ~len:(Bigstringaf.length t.read_buf - t.read_len))
    (function
      | Ok b ->
          t.read_len <- t.read_len + Bigstringaf.length b;
          consume t;
          write_runtime t
      | Error _ -> close t);
  write_runtime t;
  t

let tick t now =
  if t.websocket && not t.closed then
    match t.ping with
    | Some sent when Float.(now -. sent > 10.) -> reject t Gone
    | Some _ -> ()
    | None when Float.(now -. t.last_activity > 30.) ->
        t.ping <- Some now;
        send t 9 ""
    | None -> ()

let%test_module "Tests" =
  (module struct
    let%expect_test "websocket and binary record headers" =
      let bytes = Bytes.create 20 in
      List.iter
        (fun size ->
          let len = header bytes 2 size in
          print_endline
            (String.concat " "
               (List.init len (fun i -> Printf.sprintf "%02x" (Char.code (Bytes.get bytes i))))))
        [ 9; 126; 65536 ];
      let len = record_header bytes ~kind:Output ~offset:0x0102030405060708 ~len:3 in
      Printf.printf "%d %d %Lx\n" len (Char.code (Bytes.get bytes 2)) (Bytes.get_int64_le bytes 3);
      [%expect {|
 82 09
 82 7e 00 7e
 82 7f 00 00 00 00 00 01 00 00
 11 1 102030405060708
 |}]
  end)
