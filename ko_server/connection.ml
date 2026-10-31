external writev : Unix.file_descr -> bytes -> int -> Bigstringaf.t -> int -> int -> int
  = "ko_writev_bytecode" "ko_writev"
[@@noalloc]

external writev_batch : Unix.file_descr -> bytes -> int array -> int -> Bigstringaf.t -> int
  = "ko_writev_batch"
[@@noalloc]

type phase = Head | Body of { mutable left : int }
type ending = Open | Reject | Flushing

type t = {
  watch : Event_loop.watch;
  window : Event_loop.window;
  mutable reading : bool;
  mutable runtime : Gluten.Server.t option;
  mutable closed : bool;
  mutable waiting : bool;
  pending : Outbox.t;
  batch_headers : bytes;
  batch_spans : int array;
  mutable batch_count : int;
  headers : bytes;
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
  mutable phase : phase;
  mutable ending : ending;
  mutable head_bytes : int;
  mutable head_crlf : int;
  mutable head_scanned : int;
  mutable resume_write : unit -> unit;
  fragments : Buffer.t;
  mutable last_activity : float;
  mutable ping : float option;
}

let runtime t = Option.get t.runtime
let fd t = Event_loop.fd t.watch
let max_message = 1 lsl 20
let max_head = 16384
let batch_capacity = 64
let batch_stride = 24
let max_queued = 64 lsl 20

let close t =
  if not t.closed then begin
    t.closed <- true;
    Event_loop.close t.watch;
    t.on_close ();
    t.on_dispose t
  end

let update_interest t =
  Event_loop.interest t.watch (Event_loop.interest_of ~read:t.reading ~write:t.waiting)

let when_writable t resume =
  if (not t.closed) && not t.waiting then begin
    t.waiting <- true;
    t.resume_write <- resume;
    update_interest t
  end

let writable t =
  t.waiting <- false;
  update_interest t;
  t.resume_write ()

let refresh_window t =
  if not t.closed then begin
    let capacity = Bigstringaf.length t.read_buf in
    if t.read_pos > 0 && capacity - t.read_len < 4096 then (
      Bigstringaf.blit t.read_buf ~src_off:t.read_pos t.read_buf ~dst_off:0
        ~len:(t.read_len - t.read_pos);
      t.read_len <- t.read_len - t.read_pos;
      t.read_pos <- 0);
    t.window.off <- t.read_len;
    t.window.len <- capacity - t.read_len;
    if t.window.len = 0 && t.reading then close t
  end

let rec wait t =
  when_writable t (fun () ->
      flush t;
      if (not t.closed) && not t.waiting then t.on_writable ())

and flush t =
  if not t.closed then
    match Outbox.flush t.pending (fd t) with
    | Done -> ( match t.ending with Flushing -> close t | Open | Reject -> ())
    | Blocked -> wait t
    | Failed -> close t

let header bytes base opcode len =
  Bytes.set bytes base (Char.chr (128 lor opcode));
  if len < 126 then (
    Bytes.set bytes (base + 1) (Char.chr len);
    2)
  else if len < 65536 then (
    Bytes.set bytes (base + 1) '\126';
    Bytes.set_uint16_be bytes (base + 2) len;
    4)
  else (
    Bytes.set bytes (base + 1) '\127';
    Bytes.set_int64_be bytes (base + 2) (Int64.of_int len);
    10)

let send t opcode text =
  if not t.closed then
    if String.length text > max_message then close t
    else begin
      let len = header t.headers 0 opcode (String.length text) in
      Outbox.add t.pending (Bytes.sub_string t.headers 0 len);
      Outbox.add t.pending text;
      if t.ready then flush t
    end

let json t value = send t 1 (Yojson.Basic.to_string value)

let reject t kind =
  if t.ready && (not t.waiting) && Outbox.is_empty t.pending then
    send t 8 ("\003\240" ^ Jsonkit.Of_json.string (Protocol.error_kind_to_json kind));
  close t

let is_closed t = t.closed
let available t = t.ready && (not t.closed) && (not t.waiting) && Outbox.is_empty t.pending
let waiting t = t.waiting || not (Outbox.is_empty t.pending)

type written = Accepted | Queued | Blocked | Closed

let record_header bytes ~kind ~offset ~len =
  let at = header bytes 0 2 (len + Protocol.Record.header_size) in
  Protocol.Record.encode_header bytes at kind ~offset;
  at + Protocol.Record.header_size

let record t ~queue ~kind ~offset ring ~at ~len =
  if t.closed then Closed
  else begin
    let h = record_header t.headers ~kind ~offset ~len in
    let n = if available t then writev (fd t) t.headers h ring at len else 0 in
    if n < 0 then (
      close t;
      Closed)
    else if n = h + len then Accepted
    else if n > 0 || queue then
      if Outbox.bytes t.pending + (h + len - n) > max_queued then (
        close t;
        Closed)
      else begin
        if n < h then Outbox.add t.pending (Bytes.sub_string t.headers n (h - n));
        let skip = max 0 (n - h) in
        if skip < len then
          Outbox.add t.pending (Bigstringaf.substring ring ~off:(at + skip) ~len:(len - skip));
        if t.ready then wait t;
        Queued
      end
    else (
      if t.ready then wait t;
      Blocked)
  end

let batch_count t = t.batch_count
let batch_full t = t.batch_count = batch_capacity

let batch_add t ~offset ~at ~len =
  let i = t.batch_count in
  let base = i * batch_stride in
  let wire = header t.batch_headers base 2 (len + Protocol.Record.header_size) in
  Protocol.Record.encode_header t.batch_headers (base + wire) Output ~offset;
  let spans = t.batch_spans in
  spans.(4 * i) <- base;
  spans.((4 * i) + 1) <- wire + Protocol.Record.header_size;
  spans.((4 * i) + 2) <- at;
  spans.((4 * i) + 3) <- len;
  t.batch_count <- i + 1

let batch_send t ring =
  let count = t.batch_count in
  t.batch_count <- 0;
  if t.closed then -1
  else begin
    let n =
      if available t then writev_batch (fd t) t.batch_headers t.batch_spans count ring else 0
    in
    if n < 0 then (
      close t;
      -1)
    else begin
      let remaining = ref n and accepted = ref 0 and stop = ref false in
      while (not !stop) && !accepted < count do
        let i = !accepted in
        let base = t.batch_spans.(4 * i)
        and hl = t.batch_spans.((4 * i) + 1)
        and at = t.batch_spans.((4 * i) + 2)
        and len = t.batch_spans.((4 * i) + 3) in
        if !remaining >= hl + len then (
          remaining := !remaining - (hl + len);
          incr accepted)
        else begin
          stop := true;
          if !remaining > 0 then begin
            if !remaining < hl then
              Outbox.add t.pending
                (Bytes.sub_string t.batch_headers (base + !remaining) (hl - !remaining));
            let skip = max 0 (!remaining - hl) in
            Outbox.add t.pending (Bigstringaf.substring ring ~off:(at + skip) ~len:(len - skip));
            incr accepted
          end
        end
      done;
      if Outbox.bytes t.pending > max_queued then (
        close t;
        -1)
      else (
        if (!accepted < count || not (Outbox.is_empty t.pending)) && t.ready then wait t;
        !accepted)
    end
  end

let head_too_large =
  "HTTP/1.1 431 Request Header Fields Too Large\r\nconnection: close\r\ncontent-length: 0\r\n\r\n"

let send_head_too_large t =
  t.ending <- Flushing;
  Outbox.add t.pending head_too_large;
  flush t

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
                let n = Unix.single_write_substring (fd t) text 0 len in
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
    | `Yield -> (
        match t.ending with
        | Reject -> send_head_too_large t
        | Flushing -> ()
        | Open ->
            if t.websocket then begin
              t.ready <- true;
              flush t;
              t.on_writable ()
            end;
            t.yielded <- true;
            Gluten.Server.yield_writer (runtime t) (fun () ->
                t.yielded <- false;
                write_runtime t))
    | `Close _ -> close t

let reject_head t =
  t.ending <- Reject;
  t.reading <- false;
  update_interest t;
  if t.yielded then send_head_too_large t else write_runtime t

let head_ended = 4

let reset_head t =
  t.head_bytes <- 0;
  t.head_crlf <- 0;
  t.head_scanned <- 0

let scan_head t avail =
  if t.head_crlf <> head_ended then begin
    let i = ref t.head_scanned in
    while t.head_crlf <> head_ended && t.head_bytes <= max_head && !i < avail do
      let c = Bigstringaf.get t.read_buf (t.read_pos + !i) in
      t.head_crlf <-
        (match (t.head_crlf, c) with
        | (0 | 2), '\r' -> t.head_crlf + 1
        | (1 | 3), '\n' -> t.head_crlf + 1
        | _, '\r' -> 1
        | _ -> 0);
      t.head_bytes <- t.head_bytes + 1;
      incr i
    done;
    t.head_scanned <- !i
  end;
  if t.head_bytes <= max_head then t.head_scanned else -1

let rec consume t =
  if (not t.closed) && match t.ending with Open -> true | Reject | Flushing -> false then begin
    t.read_progress <- false;
    match Gluten.Server.next_read_operation (runtime t) with
    | `Read ->
        let avail = t.read_len - t.read_pos in
        let phase = t.phase in
        let len =
          if t.websocket || avail = 0 then avail
          else match phase with Head -> scan_head t avail | Body b -> min avail b.left
        in
        if len < 0 then reject_head t
        else begin
          let n =
            if len = 0 then 0 else Gluten.Server.read (runtime t) t.read_buf ~off:t.read_pos ~len
          in
          t.read_pos <- t.read_pos + n;
          let pending = t.read_len - t.read_pos in
          if pending = 0 then (
            t.read_pos <- 0;
            t.read_len <- 0);
          if not t.websocket then
            begin match phase with
            | Body b ->
                b.left <- b.left - n;
                if b.left = 0 then (
                  reset_head t;
                  t.phase <- Head)
            | Head ->
                t.head_scanned <- t.head_scanned - n;
                if t.head_crlf = head_ended then (if t.head_scanned = 0 then reset_head t)
                else if pending = Bigstringaf.length t.read_buf then reject_head t
            end;
          if n > 0 || t.read_progress then consume t
        end
    | `Yield ->
        t.reading <- false;
        update_interest t;
        Gluten.Server.yield_reader (runtime t) (fun () ->
            (match t.ending with
            | Open ->
                if not t.closed then begin
                  t.reading <- true;
                  update_interest t
                end
            | Reject | Flushing -> ());
            consume t;
            refresh_window t)
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

let create fd ~on_dispose =
  Unix.set_nonblock fd;
  let read_buf = Bigstringaf.create max_head in
  let t =
    {
      watch = Event_loop.watch fd;
      window = { buffer = read_buf; off = 0; len = max_head };
      reading = false;
      runtime = None;
      closed = false;
      waiting = false;
      pending = Outbox.create ();
      headers = Bytes.create 20;
      on_dispose;
      batch_headers = Bytes.create (batch_capacity * batch_stride);
      batch_spans = Array.make (4 * batch_capacity) 0;
      batch_count = 0;
      websocket = false;
      ready = false;
      yielded = false;
      on_text = ignore;
      on_close = ignore;
      on_writable = ignore;
      read_buf;
      read_len = 0;
      read_pos = 0;
      read_progress = false;
      phase = Head;
      ending = Open;
      head_bytes = 0;
      head_crlf = 0;
      head_scanned = 0;
      resume_write = ignore;
      fragments = Buffer.create 64;
      last_activity = Unix.gettimeofday ();
      ping = None;
    }
  in
  Event_loop.handle t.watch
    (Stream
       {
         window = t.window;
         on_data =
           (fun n ->
             t.read_len <- t.read_len + n;
             consume t;
             write_runtime t;
             refresh_window t);
         on_end = (fun () -> close t);
       })
    ~on_writable:(fun () -> writable t);
  t

let writer fd =
  let t = create fd ~on_dispose:ignore in
  t.ready <- true;
  t.websocket <- true;
  t

let on_request t handler ({ Gluten.reqd; _ } as request) =
  match Httpun.Request.body_length (Httpun.Reqd.request reqd) with
  | `Fixed 0L | `Error _ -> handler request
  | `Fixed n ->
      t.phase <- Body { left = Int64.to_int (Int64.min n (Int64.of_int max_int)) };
      handler request
  | `Chunked ->
      Httpun.Reqd.respond_with_string reqd
        (Httpun.Response.create
           ~headers:(Httpun.Headers.of_list [ ("connection", "close"); ("content-length", "0") ])
           `Length_required)
        ""

let accept fd ~on_dispose handler =
  let t = create fd ~on_dispose in
  t.runtime <-
    Some
      (Gluten.Server.create_upgradable
         ~protocol:(module Httpun.Server_connection)
         ~create:(fun h -> Httpun.Server_connection.create h)
         (on_request t (handler t)));
  t.reading <- true;
  update_interest t;
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
          let len = header bytes 0 2 size in
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

    let%expect_test "a view that never reads is closed before its queue grows without bound" =
      let read_end, write_end = Unix.pipe () in
      let view = writer write_end in
      let ring = Bigstringaf.create (1 lsl 20) in
      let closed_at = ref None in
      for i = 1 to 80 do
        if Option.is_none !closed_at then
          match record view ~queue:true ~kind:Snapshot ~offset:0 ring ~at:0 ~len:(1 lsl 20) with
          | Closed -> closed_at := Some i
          | Accepted | Queued | Blocked -> ()
      done;
      Printf.printf "closed within 80 MiB: %b\n" (Option.is_some !closed_at);
      Unix.close read_end;
      [%expect {| closed within 80 MiB: true |}]

    let%expect_test "a partial write inside the last batch record is flushed once the reader drains"
        =
      let writer_end, reader_end = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      Unix.setsockopt_int writer_end Unix.SO_SNDBUF 4096;
      Unix.set_nonblock reader_end;
      let view = writer writer_end in
      let sizes = [ 100; 150_000 ] in
      let ring = Bigstringaf.create (List.fold_left ( + ) 0 sizes) in
      let at = ref 0 in
      List.iter
        (fun len ->
          batch_add view ~offset:!at ~at:!at ~len;
          at := !at + len)
        sizes;
      let expected = ref 0 in
      for i = 0 to 1 do
        expected := !expected + view.batch_spans.((4 * i) + 1) + view.batch_spans.((4 * i) + 3)
      done;
      let accepted = batch_send view ring in
      Printf.printf "accepted %d of %d\n" accepted (List.length sizes);
      let received = ref 0 and chunk = Bytes.create 65536 in
      let rounds = ref 0 in
      while !received < !expected && !rounds < 1000 do
        (match Unix.read reader_end chunk 0 (Bytes.length chunk) with
        | n -> received := !received + n
        | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ());
        Event_loop.step Peek;
        incr rounds
      done;
      Printf.printf "everything arrived: %b\n" (!received = !expected);
      close view;
      Event_loop.step Peek;
      Unix.close reader_end;
      [%expect {|
        accepted 2 of 2
        everything arrived: true
      |}]

    let connect handler =
      Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
      let client, server = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      Unix.set_nonblock client;
      (client, accept server ~on_dispose:ignore handler)

    let feeder client request =
      let sent = ref 0 in
      fun () ->
        (match Unix.write_substring client request !sent (String.length request - !sent) with
        | n -> sent := !sent + n
        | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ());
        Event_loop.step Peek

    let repeat n f =
      for _ = 1 to n do
        f ()
      done

    let%expect_test "bytes that arrive while the runtime yields reading are kept until it asks" =
      let pending = ref None in
      let client, connection = connect (fun _ { Gluten.reqd; _ } -> pending := Some reqd) in
      let body = String.make 100_000 'x' in
      let feed =
        feeder client
          (Printf.sprintf "POST / HTTP/1.1\r\nHost: ko\r\nContent-Length: %d\r\n\r\n%s"
             (String.length body) body)
      in
      let received = ref 0 in
      let rec read ~again reqd =
        Httpun.Body.Reader.schedule_read (Httpun.Reqd.request_body reqd)
          ~on_read:(fun _ ~off:_ ~len ->
            received := !received + len;
            if again then read ~again reqd)
          ~on_eof:ignore
      in
      repeat 100 feed;
      Printf.printf "yielding: closed %b\n" (is_closed connection);
      Option.iter (read ~again:false) !pending;
      repeat 100 feed;
      Printf.printf "after one read: closed %b, received some %b\n" (is_closed connection)
        (!received > 0);
      Option.iter (read ~again:true) !pending;
      repeat 200 feed;
      Printf.printf "received %d of %d, closed %b\n" !received (String.length body)
        (is_closed connection);
      close connection;
      Event_loop.step Peek;
      Unix.close client;
      [%expect
        {|
        yielding: closed false
        after one read: closed false, received some true
        received 100000 of 100000, closed false
        |}]

    let respond_ok reqd =
      Httpun.Reqd.respond_with_string reqd
        (Httpun.Response.create ~headers:(Httpun.Headers.of_list [ ("content-length", "2") ]) `OK)
        "ok"

    let line prefix size = prefix ^ String.make (size - String.length prefix - 4) 'a' ^ "\r\n\r\n"

    let exchange ?(handler = fun _ { Gluten.reqd; _ } -> respond_ok reqd) writes =
      let client, connection = connect handler in
      let rounds = ref 0 in
      let rec write chunk off =
        if off < String.length chunk && !rounds < 2000 then begin
          incr rounds;
          match Unix.write_substring client chunk off (String.length chunk - off) with
          | n -> write chunk (off + n)
          | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
              Event_loop.step Peek;
              write chunk off
          | exception Unix.Unix_error _ -> ()
        end
        else Event_loop.step Peek
      in
      List.iter
        (fun chunk ->
          rounds := 0;
          write chunk 0)
        writes;
      let reply = Buffer.create 256 and chunk = Bytes.create 4096 in
      let eof = ref false in
      repeat 50 (fun () ->
          Event_loop.step Peek;
          try
            while not !eof do
              match Unix.read client chunk 0 4096 with
              | 0 -> eof := true
              | n -> Buffer.add_subbytes reply chunk 0 n
            done
          with Unix.Unix_error _ -> ());
      let statuses =
        match String.split ~by:"HTTP/1.1 " (Buffer.contents reply) with
        | _ :: replies -> List.map (fun r -> String.sub r 0 3) replies
        | [] -> []
      in
      let buffered = connection.read_len - connection.read_pos in
      let closed = is_closed connection in
      close connection;
      Event_loop.step Peek;
      Unix.close client;
      (statuses, closed, buffered)

    let%expect_test "a request head is limited as a whole, however it arrives" =
      let prefix = "GET / HTTP/1.1\r\nHost: ko\r\nX: " in
      let show name (statuses, closed, buffered) =
        Printf.printf "%s: %s closed %b bounded %b\n" name (String.concat "," statuses) closed
          (buffered <= max_head)
      in
      List.iter
        (fun size -> show (string_of_int size) (exchange [ line prefix size ]))
        [ max_head - 1; max_head; max_head + 1 ];
      let split = line prefix (max_head + 1) in
      show "split limit"
        (exchange
           (List.init (max_head / 7) (fun i -> String.sub split (i * 7) 7)
           @ [ String.sub split (max_head / 7 * 7) (String.length split - (max_head / 7 * 7)) ]));
      List.iter
        (fun size ->
          show (Printf.sprintf "line %d" size)
            (exchange [ "GET /" ^ String.make (size - 18) 'a' ^ " HTTP/1.1\r\n\r\n" ]))
        [
          max_head - 1;
          max_head;
          max_head + 1;
          max_head + 2;
          max_head + 100;
          max_head + 4000;
          4 * max_head;
        ];
      let many =
        "GET / HTTP/1.1\r\nHost: ko\r\n" ^ String.concat "" (List.init 4000 (fun _ -> "A: b\r\n"))
      in
      show "many headers" (exchange [ many ^ "\r\n" ]);
      let small = "GET / HTTP/1.1\r\nHost: ko\r\nX: " ^ String.make 9000 'a' ^ "\r\n\r\n" in
      show "two pipelined" (exchange [ small ^ small ]);
      let reached = ref false in
      let upgrade =
        "GET /client HTTP/1.1\r\n\
         Host: ko\r\n\
         Upgrade: websocket\r\n\
         Connection: Upgrade\r\n\
         Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\
         Sec-WebSocket-Version: 13\r\n\
         X: "
      in
      show "oversized upgrade"
        (exchange ~handler:(fun _ _ -> reached := true) [ line upgrade (max_head + 1) ]);
      Printf.printf "upgrade handler reached: %b\n" !reached;
      let body = String.make 40_000 'b' in
      show "head then 40000 body bytes then head"
        (exchange
           [
             Printf.sprintf "POST / HTTP/1.1\r\nHost: ko\r\nContent-Length: %d\r\n\r\n%s"
               (String.length body) body
             ^ small;
           ]);
      [%expect
        {|
        16383: 200 closed false bounded true
        16384: 200 closed false bounded true
        16385: 431 closed true bounded true
        split limit: 431 closed true bounded true
        line 16383: 200 closed false bounded true
        line 16384: 200 closed false bounded true
        line 16385: 431 closed true bounded true
        line 16386: 431 closed true bounded true
        line 16484: 431 closed true bounded true
        line 20384: 431 closed true bounded true
        line 65536: 431 closed true bounded true
        many headers: 431 closed true bounded true
        two pipelined: 200,200 closed false bounded true
        oversized upgrade: 431 closed true bounded true
        upgrade handler reached: false
        head then 40000 body bytes then head: 200,200 closed false bounded true
        |}]

    let%expect_test "a request head that never ends does not grow the heap" =
      let client, connection = connect (fun _ { Gluten.reqd; _ } -> respond_ok reqd) in
      let data =
        "GET / HTTP/1.1\r\nHost: ko\r\n"
        ^ String.concat "" (List.init 700_000 (fun _ -> "A: b\r\n"))
      in
      Gc.full_major ();
      let before = (Gc.stat ()).live_words in
      let sent = ref 0 and idle = ref 0 in
      while !sent < String.length data && !idle < 200 do
        (match Unix.write_substring client data !sent (String.length data - !sent) with
        | n ->
            sent := !sent + n;
            idle := 0
        | exception Unix.Unix_error _ -> incr idle);
        Event_loop.step Peek
      done;
      Gc.full_major ();
      let grown = (Gc.stat ()).live_words - before in
      ignore (Sys.opaque_identity data);
      Printf.printf "closed %b, client sent < 1 MiB: %b, heap grew < 1 MiB: %b\n"
        (is_closed connection)
        (!sent < 1 lsl 20)
        (grown * 8 < 1 lsl 20);
      close connection;
      Event_loop.step Peek;
      Unix.close client;
      [%expect {| closed true, client sent < 1 MiB: true, heap grew < 1 MiB: true |}]

    let%expect_test
        "an oversized head after a pipelined request is answered after the full first response" =
      let size = 3_000_000 in
      let client, connection =
        connect (fun _ { Gluten.reqd; _ } ->
            Httpun.Reqd.respond_with_string reqd
              (Httpun.Response.create
                 ~headers:(Httpun.Headers.of_list [ ("content-length", string_of_int size) ])
                 `OK)
              (String.make size 'x'))
      in
      let data =
        "GET / HTTP/1.1\r\nHost: ko\r\n\r\n" ^ line "GET / HTTP/1.1\r\nX: " (max_head + 1)
      in
      let sent = ref 0 in
      repeat 200 (fun () ->
          (match Unix.write_substring client data !sent (String.length data - !sent) with
          | n -> sent := !sent + n
          | exception Unix.Unix_error _ -> ());
          Event_loop.step Peek);
      let reply = Buffer.create (size + 1024) and chunk = Bytes.create 65536 in
      let eof = ref false and rounds = ref 0 in
      while (not !eof) && !rounds < 20000 do
        incr rounds;
        Event_loop.step Peek;
        match Unix.read client chunk 0 65536 with
        | 0 -> eof := true
        | n -> Buffer.add_subbytes reply chunk 0 n
        | exception Unix.Unix_error _ -> ()
      done;
      let reply = Buffer.contents reply in
      let first = "HTTP/1.1 200 OK" in
      let tail = String.length reply - String.length head_too_large in
      let xs = String.fold (fun n c -> if Char.equal c 'x' then n + 1 else n) 0 reply in
      Printf.printf "eof %b, starts with 200 %b, body bytes %d of %d, ends with whole 431 %b\n" !eof
        (String.starts_with ~prefix:first reply)
        xs size
        (tail >= 0
        && String.equal (String.sub reply tail (String.length head_too_large)) head_too_large);
      close connection;
      Event_loop.step Peek;
      Unix.close client;
      [%expect
        {| eof true, starts with 200 true, body bytes 3000000 of 3000000, ends with whole 431 true |}]
  end)
