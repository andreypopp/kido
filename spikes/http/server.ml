let ok what = function
  | Ok v -> v
  | Error e -> failwith (Printf.sprintf "%s: %s" what (Luv.Error.strerror e))

let ring_size = 1 lsl 20
let index_cap = 8192
let header = 9

type config = {
  socket : string;
  panes : int;
  chunk : int;
  tick_ms : int;
  threshold : int;
  snapshot : int;
  sndbuf : int;
}

type pane = {
  ring : Bigstringaf.t;
  index : int array;
  mutable write_pos : int;
  mutable virt : int;
  mutable head_offset : int;
  mutable head_seq : int;
  mutable oldest_seq : int;
  mutable stalled_since : float option;
  mutable views : view list;
}

and view = {
  pane : pane;
  conn : conn;
  wsd : Httpun_ws.Wsd.t;
  mutable next_seq : int;
  mutable backlogged : bool;
  mutable unwritten_seq : int option;
  mutable pinned_virt : int option;
  mutable records : int;
  mutable bytes : int;
  mutable skips : int;
}

and conn = {
  stream : Luv.Pipe.t;
  mutable runtime : Gluten.Server.t option;
  mutable view : view option;
  mutable blocked : bool;
  mutable dirty : bool;
  mutable yielded : bool;
  mutable closed : bool;
  read_buf : Bigstringaf.t;
  mutable read_len : int;
}

type totals = {
  mutable records : int;
  mutable bytes : int;
  mutable skips : int;
  mutable lapped : int;
  mutable blocks : int;
  mutable copied : int;
  mutable pins : int;
  mutable pin_ms : int list;
  mutable writer_stalls : int;
  mutable writer_stall_ms : int list;
  mutable stalled_ticks : int;
  mutable accepted : int;
  mutable refused : int;
  mutable sndbuf_read_back : int;
  mutable rcvbuf_read_back : int;
  mutable words_schedule : int;
  mutable words_iovecs : int;
  mutable words_try_write : int;
  mutable writes : int;
}

let totals =
  {
    records = 0;
    bytes = 0;
    skips = 0;
    lapped = 0;
    blocks = 0;
    copied = 0;
    pins = 0;
    pin_ms = [];
    writer_stalls = 0;
    writer_stall_ms = [];
    stalled_ticks = 0;
    accepted = 0;
    refused = 0;
    sndbuf_read_back = 0;
    rcvbuf_read_back = 0;
    words_schedule = 0;
    words_iovecs = 0;
    words_try_write = 0;
    writes = 0;
  }

let dirty : conn list ref = ref []
let words () = Float.to_int (Gc.minor_words ())
let slot seq = seq mod index_cap * 4

let virt_after pane total =
  if pane.write_pos + total > ring_size then pane.virt + (ring_size - pane.write_pos) + total
  else pane.virt + total

let pinned pane =
  List.fold_left
    (fun acc v -> match v.pinned_virt with Some p -> min acc p | None -> acc)
    max_int pane.views

let blocks_writer pane ~len = virt_after pane (header + len) - pinned pane > ring_size

let append pane ~len ~fill =
  let total = header + len in
  if pane.write_pos + total > ring_size then begin
    pane.virt <- pane.virt + (ring_size - pane.write_pos);
    pane.write_pos <- 0
  end;
  let pos = pane.write_pos in
  Bigstringaf.set pane.ring pos '\001';
  Bigstringaf.set_int64_le pane.ring (pos + 1) (Int64.of_int pane.head_offset);
  fill pane.ring (pos + header);
  let at = slot pane.head_seq in
  pane.index.(at) <- pos;
  pane.index.(at + 1) <- total;
  pane.index.(at + 2) <- pane.head_offset;
  pane.index.(at + 3) <- pane.virt;
  pane.write_pos <- pos + total;
  pane.virt <- pane.virt + total;
  pane.head_offset <- pane.head_offset + len;
  pane.head_seq <- pane.head_seq + 1;
  while
    pane.head_seq - pane.oldest_seq > index_cap
    || pane.virt - pane.index.(slot pane.oldest_seq + 3) > ring_size
  do
    pane.oldest_seq <- pane.oldest_seq + 1
  done

let runtime conn = Option.get_exn_or "runtime" conn.runtime

let mark_dirty conn =
  if not conn.dirty then begin
    conn.dirty <- true;
    dirty := conn :: !dirty
  end

let close conn =
  if not conn.closed then begin
    conn.closed <- true;
    Option.iter
      (fun v -> v.pane.views <- List.filter (fun w -> not (Stdlib.( == ) w v)) v.pane.views)
      conn.view;
    Luv.Handle.close conn.stream ignore
  end

let skip config view =
  let pane = view.pane in
  let note =
    Printf.sprintf {|{"offset":%d,"skipped":{"from":%d,"to":%d}}|} pane.head_offset
      (if view.next_seq >= pane.oldest_seq then pane.index.(slot view.next_seq + 2) else -1)
      pane.head_offset
  in
  Httpun_ws.Wsd.send_bytes view.wsd ~kind:`Text (Bytes.of_string note) ~off:0
    ~len:(String.length note);
  let snap = Bigstringaf.create (header + config.snapshot) in
  Bigstringaf.set snap 0 '\002';
  Bigstringaf.set_int64_le snap 1 (Int64.of_int pane.head_offset);
  Bigarray.Array1.fill (Bigstringaf.sub snap ~off:header ~len:config.snapshot) 's';
  Httpun_ws.Wsd.schedule view.wsd ~kind:`Binary snap ~off:0 ~len:(Bigstringaf.length snap);
  view.next_seq <- pane.head_seq;
  view.skips <- view.skips + 1;
  totals.skips <- totals.skips + 1

let pump config view =
  let pane = view.pane in
  if (not view.conn.blocked) && (not view.conn.closed) && view.next_seq < pane.head_seq then (
    let backlogged = view.backlogged in
    view.backlogged <- false;
    if view.next_seq < pane.oldest_seq then begin
      totals.lapped <- totals.lapped + 1;
      skip config view
    end
    else if backlogged && pane.head_offset - pane.index.(slot view.next_seq + 2) >= config.threshold
    then skip config view
    else begin
      if Option.is_none view.unwritten_seq then view.unwritten_seq <- Some view.next_seq;
      for seq = view.next_seq to pane.head_seq - 1 do
        let at = slot seq in
        let len = pane.index.(at + 1) in
        let w0 = words () in
        Httpun_ws.Wsd.schedule view.wsd ~kind:`Binary pane.ring ~off:pane.index.(at) ~len;
        totals.words_schedule <- totals.words_schedule + (words () - w0);
        view.records <- view.records + 1;
        view.bytes <- view.bytes + len;
        totals.records <- totals.records + 1;
        totals.bytes <- totals.bytes + len
      done;
      view.next_seq <- pane.head_seq
    end)

let rec write_loop config conn =
  if (not conn.blocked) && (not conn.yielded) && not conn.closed then
    let rt = runtime conn in
    match Gluten.Server.next_write_operation rt with
    | `Write iovecs -> (
        let w0 = words () in
        let bufs =
          List.map (fun { Faraday.buffer; off; len } -> Bigstringaf.sub buffer ~off ~len) iovecs
        in
        let total = Luv.Buffer.total_size bufs in
        let w1 = words () in
        let written =
          match Luv.Stream.try_write conn.stream bufs with
          | Ok n -> Ok n
          | Error `EAGAIN -> Ok 0
          | Error e -> Error e
        in
        let w2 = words () in
        totals.words_iovecs <- totals.words_iovecs + (w1 - w0);
        totals.words_try_write <- totals.words_try_write + (w2 - w1);
        totals.writes <- totals.writes + 1;
        match written with
        | Ok n when n = total ->
            Option.iter (fun v -> v.unwritten_seq <- None) conn.view;
            Gluten.Server.report_write_result rt (`Ok n);
            write_loop config conn
        | Ok n ->
            let is_ring buffer =
              match conn.view with Some v -> Stdlib.( == ) buffer v.pane.ring | None -> false
            in
            let rest =
              List.rev
                (snd
                   (List.fold_left
                      (fun (skip, acc) { Faraday.buffer; off; len } ->
                        if skip >= len then (skip - len, acc)
                        else
                          let off = off + skip and len = len - skip in
                          let b =
                            if is_ring buffer then Bigstringaf.sub buffer ~off ~len
                            else begin
                              totals.copied <- totals.copied + len;
                              Bigstringaf.copy buffer ~off ~len
                            end
                          in
                          (0, b :: acc))
                      (n, []) iovecs))
            in
            conn.blocked <- true;
            totals.blocks <- totals.blocks + 1;
            let started = Unix.gettimeofday () in
            Option.iter
              (fun v ->
                v.backlogged <- true;
                v.pinned_virt <- Option.map (fun seq -> v.pane.index.(slot seq + 3)) v.unwritten_seq;
                if Option.is_some v.pinned_virt then totals.pins <- totals.pins + 1)
              conn.view;
            Gluten.Server.report_write_result rt (`Ok total);
            Luv.Stream.write conn.stream rest (fun r _ ->
                conn.blocked <- false;
                Option.iter
                  (fun v ->
                    if Option.is_some v.pinned_virt then
                      totals.pin_ms <-
                        Float.to_int ((Unix.gettimeofday () -. started) *. 1000.) :: totals.pin_ms;
                    v.pinned_virt <- None;
                    v.unwritten_seq <- None)
                  conn.view;
                match r with
                | Ok () ->
                    Option.iter (pump config) conn.view;
                    write_loop config conn
                | Error _ -> close conn)
        | Error _ ->
            Gluten.Server.report_write_result rt `Closed;
            close conn)
    | `Yield ->
        conn.yielded <- true;
        Gluten.Server.yield_writer rt (fun () ->
            conn.yielded <- false;
            mark_dirty conn)
    | `Close _ -> close conn

let rec consume config conn =
  if not conn.closed then
    let rt = runtime conn in
    match Gluten.Server.next_read_operation rt with
    | `Read when conn.read_len > 0 ->
        let n = Gluten.Server.read rt conn.read_buf ~off:0 ~len:conn.read_len in
        Bigstringaf.blit conn.read_buf ~src_off:n conn.read_buf ~dst_off:0 ~len:(conn.read_len - n);
        conn.read_len <- conn.read_len - n;
        if n > 0 then consume config conn
    | `Read -> ()
    | `Yield -> Gluten.Server.yield_reader rt (fun () -> consume config conn)
    | `Close -> close conn

let start_reading config conn =
  Luv.Stream.read_start conn.stream
    ~allocate:(fun _ ->
      Bigstringaf.sub conn.read_buf ~off:conn.read_len
        ~len:(Bigstringaf.length conn.read_buf - conn.read_len))
    (function
      | Ok b ->
          conn.read_len <- conn.read_len + Bigstringaf.length b;
          consume config conn;
          mark_dirty conn
      | Error `EOF ->
          ignore
            (Gluten.Server.read_eof (runtime conn) conn.read_buf ~off:0 ~len:conn.read_len : int);
          close conn
      | Error _ -> close conn)

let percentiles l =
  match List.sort Int.compare l with
  | [] -> "[0,0,0]"
  | sorted ->
      let a = Array.of_list sorted in
      let at p = a.(min (Array.length a - 1) (Array.length a * p / 100)) in
      Printf.sprintf "[%d,%d,%d]" (at 50) (at 99) a.(Array.length a - 1)

let stats_json panes =
  let user, sys =
    let t = Unix.times () in
    (t.tms_utime, t.tms_stime)
  in
  let views =
    Array.to_list panes
    |> List.concat_map (fun pane -> pane.views)
    |> List.map (fun (v : view) ->
        Printf.sprintf {|{"records":%d,"bytes":%d,"skips":%d}|} v.records v.bytes v.skips)
    |> String.concat ","
  in
  Printf.sprintf
    {|{"now":%f,"user":%f,"sys":%f,"minor_words":%d,"records":%d,"bytes":%d,"skips":%d,"lapped":%d,"blocks":%d,"copied":%d,"pins":%d,"pin_ms":%s,"writer_stalls":%d,"writer_stall_ms":%s,"stalled_ticks":%d,"accepted":%d,"refused":%d,"sndbuf":%d,"rcvbuf":%d,"words_schedule":%d,"words_iovecs":%d,"words_try_write":%d,"writes":%d,"views":[%s]}|}
    (Unix.gettimeofday ()) user sys (words ()) totals.records totals.bytes totals.skips
    totals.lapped totals.blocks totals.copied totals.pins (percentiles totals.pin_ms)
    totals.writer_stalls
    (percentiles totals.writer_stall_ms)
    totals.stalled_ticks totals.accepted totals.refused totals.sndbuf_read_back
    totals.rcvbuf_read_back totals.words_schedule totals.words_iovecs totals.words_try_write
    totals.writes views

let websocket config conn pane wsd =
  let view =
    {
      pane;
      conn;
      wsd;
      next_seq = pane.head_seq;
      backlogged = false;
      unwritten_seq = None;
      pinned_virt = None;
      records = 0;
      bytes = 0;
      skips = 0;
    }
  in
  conn.view <- Some view;
  pane.views <- view :: pane.views;
  let frame ~opcode ~is_fin:_ ~len:_ payload =
    let text = Buffer.create 32 in
    let rec read () =
      Httpun_ws.Payload.schedule_read payload
        ~on_read:(fun bs ~off ~len ->
          Buffer.add_string text (Bigstringaf.substring bs ~off ~len);
          read ())
        ~on_eof:(fun () ->
          match opcode with
          | `Text ->
              let s = Buffer.contents text in
              append pane ~len:(String.length s) ~fill:(fun ring at ->
                  Bigstringaf.blit_from_string s ~src_off:0 ring ~dst_off:at ~len:(String.length s));
              pump config view
          | `Connection_close -> Httpun_ws.Wsd.close wsd
          | `Ping -> Httpun_ws.Wsd.send_pong wsd
          | _ -> ())
    in
    read ()
  in
  { Httpun_ws.Websocket_connection.frame; eof = (fun ?error:_ () -> close conn) }

let request_handler config panes conn { Gluten.reqd; upgrade } =
  let target = (Httpun.Reqd.request reqd).target in
  let respond status body =
    Httpun.Reqd.respond_with_string reqd
      (Httpun.Response.create
         ~headers:
           (Httpun.Headers.of_list [ ("content-length", Int.to_string (String.length body)) ])
         status)
      body
  in
  match String.chop_prefix ~pre:"/panes/pane_" target with
  | Some rest -> (
      match int_of_string_opt (String.take_while (fun c -> not (Char.equal c '/')) rest) with
      | Some n when n >= 0 && n < Array.length panes -> (
          match
            Httpun_ws.Handshake.respond_with_upgrade ~sha1:Http_spike.Sha1.digest reqd (fun () ->
                upgrade
                  (Gluten.make
                     (module Httpun_ws.Server_connection)
                     (Httpun_ws.Server_connection.create_websocket
                        (websocket config conn panes.(n)))))
          with
          | Ok () -> ()
          | Error msg -> respond `Bad_request msg)
      | _ -> respond `Not_found "no pane")
  | None -> (
      match target with
      | "/stats" -> respond `OK (stats_json panes)
      | "/mark" ->
          totals.pin_ms <- [];
          totals.writer_stall_ms <- [];
          respond `OK "marked"
      | "/quit" ->
          respond `OK "bye";
          exit 0
      | _ -> respond `Not_found "not found")

let () =
  let args = Array.to_list Sys.argv |> List.tl in
  let get name default =
    let rec find = function
      | k :: v :: _ when String.equal k ("--" ^ name) -> v
      | _ :: rest -> find rest
      | [] -> default
    in
    find args
  in
  let config =
    {
      socket = get "socket" "";
      panes = int_of_string (get "panes" "50");
      chunk = int_of_string (get "chunk" "16384");
      tick_ms = int_of_string (get "tick-ms" "2");
      threshold = int_of_string (get "threshold" "65536");
      snapshot = int_of_string (get "snapshot" "32768");
      sndbuf = int_of_string (get "sndbuf" "1048576");
    }
  in
  let panes =
    Array.init config.panes (fun _ ->
        let ring = Bigstringaf.create ring_size in
        Bigarray.Array1.fill ring 'x';
        {
          ring;
          index = Array.make (index_cap * 3) 0;
          write_pos = 0;
          virt = 0;
          head_offset = 0;
          head_seq = 0;
          oldest_seq = 0;
          stalled_since = None;
          views = [];
        })
  in
  let server = ok "init" (Luv.Pipe.init ()) in
  ok "bind" (Luv.Pipe.bind server config.socket);
  let me = Unix.getuid () in
  Luv.Stream.listen ~backlog:256 server (fun r ->
      ok "listen" r;
      let stream = ok "init" (Luv.Pipe.init ()) in
      ok "accept" (Luv.Stream.accept ~server ~client:stream);
      match Http_spike.Peer.uid stream with
      | exception Unix.Unix_error _ ->
          totals.refused <- totals.refused + 1;
          Luv.Handle.close stream ignore
      | Ok uid when uid = me ->
          totals.accepted <- totals.accepted + 1;
          if config.sndbuf > 0 then
            ok "sndbuf" (Luv.Handle.set_send_buffer_size stream config.sndbuf);
          totals.sndbuf_read_back <- ok "sndbuf" (Luv.Handle.send_buffer_size stream);
          totals.rcvbuf_read_back <- ok "rcvbuf" (Luv.Handle.recv_buffer_size stream);
          let conn =
            {
              stream;
              runtime = None;
              view = None;
              blocked = false;
              dirty = false;
              yielded = false;
              closed = false;
              read_buf = Bigstringaf.create 16384;
              read_len = 0;
            }
          in
          conn.runtime <-
            Some
              (Gluten.Server.create_upgradable
                 ~protocol:(module Httpun.Server_connection)
                 ~create:(fun h -> Httpun.Server_connection.create h)
                 (request_handler config panes conn));
          start_reading config conn;
          write_loop config conn
      | _ ->
          totals.refused <- totals.refused + 1;
          Luv.Handle.close stream ignore);
  let flush () =
    let l = !dirty in
    dirty := [];
    List.iter
      (fun c ->
        c.dirty <- false;
        write_loop config c)
      l
  in
  let prepare = ok "prepare" (Luv.Prepare.init ()) in
  ok "prepare" (Luv.Prepare.start prepare flush);
  let check = ok "check" (Luv.Check.init ()) in
  ok "check" (Luv.Check.start check flush);
  let timer = ok "timer" (Luv.Timer.init ()) in
  ok "timer"
    (Luv.Timer.start ~repeat:config.tick_ms timer config.tick_ms (fun () ->
         for i = 1 to Array.length panes - 1 do
           let pane = panes.(i) in
           if config.chunk > 0 && not (List.is_empty pane.views) then
             if blocks_writer pane ~len:config.chunk then begin
               totals.stalled_ticks <- totals.stalled_ticks + 1;
               if Option.is_none pane.stalled_since then begin
                 totals.writer_stalls <- totals.writer_stalls + 1;
                 pane.stalled_since <- Some (Unix.gettimeofday ())
               end
             end
             else begin
               Option.iter
                 (fun t ->
                   totals.writer_stall_ms <-
                     Float.to_int ((Unix.gettimeofday () -. t) *. 1000.) :: totals.writer_stall_ms)
                 pane.stalled_since;
               pane.stalled_since <- None;
               append pane ~len:config.chunk ~fill:(fun _ _ -> ())
             end
         done;
         Array.iter (fun pane -> List.iter (pump config) pane.views) panes));
  Printf.printf "listening %s\n%!" config.socket;
  ignore (Luv.Loop.run () : bool)
