type layout = {
  data_offset : int;
  record_header : int;
  view_header_max : int;
  bytes : int;
  slice : int;
  pad : int;
  init : int;
  tail : int;
  resize : int;
  snapshot : int;
  exit : int;
  ready : int;
  dead : int;
  snapshot_done : int;
  full : int;
}

type state = (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t

external layout : unit -> layout = "ko_spike_layout"
external start_pane : string -> bool -> Luv.Buffer.t * Unix.file_descr * int = "ko_spike_start"
external unmap : Luv.Buffer.t -> unit = "ko_spike_unmap"
external openpty : unit -> Unix.file_descr * Unix.file_descr = "ko_spike_pty"
external now_ns : unit -> int = "ko_spike_now_ns" [@@noalloc]
external cpu_seconds : int -> float * float = "ko_spike_cpu_seconds"
external ring_head : Luv.Buffer.t -> int = "ko_spike_ring_head" [@@noalloc]
external ring_set_tail : Luv.Buffer.t -> int -> unit = "ko_spike_ring_set_tail" [@@noalloc]
external view_header : Luv.Buffer.t -> int -> Luv.Buffer.t -> int -> int = "ko_spike_view_header" [@@noalloc]
external view_writev : Unix.file_descr -> Luv.Buffer.t -> state -> int -> int = "ko_spike_view_writev" [@@noalloc]

let layout = layout ()
let max_in_flight = 64
let max_batch = 512

let get buffer index = Char.code (Bigarray.Array1.unsafe_get buffer index)

let get_u32 buffer index =
  get buffer index
  lor (get buffer (index + 1) lsl 8)
  lor (get buffer (index + 2) lsl 16)
  lor (get buffer (index + 3) lsl 24)

let get_u64 buffer index = get_u32 buffer index lor (get_u32 buffer (index + 4) lsl 32)

let put_le bytes index value width =
  for i = 0 to width - 1 do
    Bytes.set bytes (index + i) (Char.chr ((value lsr (8 * i)) land 0xff))
  done

let ok what = function
  | Ok v -> v
  | Error e -> failwith (Printf.sprintf "%s: %s" what (Luv.Error.strerror e))

(* luv_unix is not in dune.lock; Luv.File.t is the int descriptor on Unix (luv's luv_c_type_descriptions.ml). *)
let file (fd : Unix.file_descr) : Luv.File.t = Obj.magic fd

let pipe fd =
  let pipe = ok "pipe" (Luv.Pipe.init ()) in
  ok "pipe open" (Luv.Pipe.open_ pipe (file fd));
  pipe

let frame kind body =
  let b = Buffer.create (String.length body + 5) in
  Buffer.add_int32_le b (Int32.of_int (String.length body + 1));
  Buffer.add_char b (Char.chr kind);
  Buffer.add_string b body;
  Luv.Buffer.from_string (Buffer.contents b)

let init_body ~argv =
  let b = Buffer.create 256 in
  let u16 v = Buffer.add_uint16_le b v in
  let u64 v = Buffer.add_int64_le b (Int64.of_int v) in
  let str s =
    Buffer.add_int32_le b (Int32.of_int (String.length s));
    Buffer.add_string b s
  in
  let strs l =
    Buffer.add_int32_le b (Int32.of_int (List.length l));
    List.iter str l
  in
  List.iter u16 [ 1; 80; 24; 8; 16 ];
  u64 (32 * 1024 * 1024);
  u64 (65 * 1024 * 1024);
  u64 (10 * 1000 * 1000);
  Buffer.add_char b '\000';
  u64 (65 * 1024 * 1024);
  str "/";
  strs argv;
  strs [ "TERM=xterm-ghostty" ];
  str "pane_1";
  Buffer.contents b

type variant = Luv_write | Writev

type stream = {
  pipe : Luv.Pipe.t;
  headers : Luv.Buffer.t;
  slots : int;
  mutable next_slot : int;
  ends : int array;
  mutable first_end : int;
  mutable in_flight : int;
  batch_index : int array;
  batch_slot : int array;
  batch_header : int array;
  batch_len : int array;
  mutable sent : int;
}

type raw = { fd : Unix.file_descr; poll : Luv.Poll.t; state : state; mutable waiting : bool }
type view = Stream of stream | Raw of raw

type pane = {
  ring : Luv.Buffer.t;
  capacity : int;
  control : Luv.Pipe.t;
  view : view;
  pid : int;
  input : Luv.Buffer.t;
  mutable filled : int;
  mutable head : int;
  mutable tail : int;
  mutable full_seen : int;
  tail_bytes : Bytes.t;
  tail_frame : Luv.Buffer.t list;
  mutable records : int;
  mutable payload : int;
  mutable reads : int;
  mutable writes : int;
  mutable dead : bool;
  mutable pane_cpu : float;
  observe : bool;
  mutable observed : int;
  mutable slices : int;
  transcript : Buffer.t option;
  latencies : int array;
  mutable samples : int;
  mutable on_frame : int -> unit;
  mutable on_drained : unit -> unit;
  coalesce_ns : int;
  timer : Luv.Timer.t;
  mutable armed : bool;
  mutable last_flush : int;
  mutable on_timer : unit -> unit;
  mutable written : (unit, Luv.Error.t) result -> int -> unit;
  mutable writable : (Luv.Poll.Event.t list, Luv.Error.t) result -> unit;
}

let record_at pane pos = layout.data_offset + (pos mod pane.capacity)

let sent pane = match pane.view with Stream s -> s.sent | Raw r -> Int64.to_int r.state.{0}

let observe pane =
  while pane.observed < pane.head do
    let at = record_at pane pane.observed in
    let kind = get pane.ring at and len = get_u32 pane.ring (at + 1) in
    (match pane.transcript with
    | Some b when kind = layout.bytes ->
        if Buffer.length b > 4 lsl 20 then begin
          let keep = Buffer.sub b (Buffer.length b - (1 lsl 20)) (1 lsl 20) in
          Buffer.clear b;
          Buffer.add_string b keep
        end;
        for i = at + layout.record_header to at + layout.record_header + len - 1 do
          Buffer.add_char b (Bigarray.Array1.unsafe_get pane.ring i)
        done
    | _ -> ());
    if kind = layout.slice then pane.slices <- pane.slices + len - 2
    else if kind = layout.bytes && Array.length pane.latencies > 0 then begin
      let i = ref (at + layout.record_header) and stop = at + layout.record_header + len - 21 in
      while !i <= stop do
        if Char.equal (Bigarray.Array1.unsafe_get pane.ring !i) 'T' && pane.samples < Array.length pane.latencies
        then begin
          let ts = ref 0 in
          for d = 1 to 20 do
            ts := (!ts * 10) + get pane.ring (!i + d) - 48
          done;
          pane.latencies.(pane.samples) <- now_ns () - !ts;
          pane.samples <- pane.samples + 1;
          i := !i + 21
        end
        else incr i
      done
    end;
    pane.observed <- pane.observed + layout.record_header + len
  done

let send_tail pane =
  put_le pane.tail_bytes 5 pane.tail 8;
  Luv.Buffer.blit_from_bytes (List.hd pane.tail_frame) pane.tail_bytes ~source_offset:0;
  match Luv.Stream.try_write pane.control pane.tail_frame with
  | Ok 13 -> ()
  | Ok _ | Error `EAGAIN -> failwith "the spike assumes a 13-byte write to an empty socket succeeds"
  | Error e -> failwith (Luv.Error.strerror e)

let set_tail pane tail =
  if tail > pane.tail then begin
    pane.tail <- tail;
    ring_set_tail pane.ring tail;
    if pane.full_seen >= 0 && tail > pane.full_seen then begin
      pane.full_seen <- -1;
      send_tail pane
    end
  end

let rec flush_stream pane s =
  if s.sent < pane.head && s.in_flight < max_in_flight then begin
    let start = s.sent in
    let pos = ref start and after_pad = ref (-1) and count = ref 0 in
    while
      !after_pad < 0 && !pos < pane.head && !count < max_batch && (!pos = start || !pos mod pane.capacity <> 0)
    do
      let at = record_at pane !pos in
      let kind = get pane.ring at and len = get_u32 pane.ring (at + 1) in
      if kind = layout.pad then after_pad := !pos + layout.record_header + len
      else begin
        let slot = s.next_slot in
        s.next_slot <- (slot + 1) mod s.slots;
        s.batch_index.(!count) <- at;
        s.batch_slot.(!count) <- slot;
        s.batch_header.(!count) <- view_header s.headers slot pane.ring at;
        s.batch_len.(!count) <- len;
        incr count;
        pane.records <- pane.records + 1;
        if kind = layout.bytes then pane.payload <- pane.payload + len;
        pos := !pos + layout.record_header + len
      end
    done;
    let finish = if !after_pad >= 0 then !after_pad else !pos in
    s.sent <- finish;
    if !count > 0 then begin
      let buffers = ref [] in
      for i = !count - 1 downto 0 do
        buffers :=
          Luv.Buffer.sub s.headers ~offset:(s.batch_slot.(i) * layout.view_header_max) ~length:s.batch_header.(i)
          :: Luv.Buffer.sub pane.ring ~offset:(s.batch_index.(i) + layout.record_header) ~length:s.batch_len.(i)
          :: !buffers
      done;
      s.ends.((s.first_end + s.in_flight) mod max_in_flight) <- finish;
      s.in_flight <- s.in_flight + 1;
      pane.writes <- pane.writes + 1;
      Luv.Stream.write s.pipe !buffers pane.written
    end
    else if s.in_flight = 0 then set_tail pane finish
    else s.ends.((s.first_end + s.in_flight - 1) mod max_in_flight) <- finish;
    flush_stream pane s
  end

let rec flush pane =
  pane.head <- ring_head pane.ring;
  if pane.observe then observe pane;
  (match pane.view with
  | Stream s -> flush_stream pane s
  | Raw r when not r.waiting ->
      pane.writes <- pane.writes + 1;
      let result = view_writev r.fd pane.ring r.state pane.head in
      pane.records <- Int64.to_int r.state.{2};
      pane.payload <- Int64.to_int r.state.{3};
      set_tail pane (Int64.to_int r.state.{0});
      if result = 1 then begin
        r.waiting <- true;
        Luv.Poll.start r.poll [ `WRITABLE ] pane.writable
      end
      else if result < 0 then failwith (Printf.sprintf "writev: errno %d" (-result))
  | Raw _ -> ());
  let more = ring_head pane.ring > sent pane in
  match pane.view with
  | Stream s when s.in_flight >= max_in_flight -> ()
  | Stream s -> if more then schedule pane else if s.in_flight = 0 then pane.on_drained ()
  | Raw r when r.waiting -> ()
  | Raw _ -> if more then schedule pane else pane.on_drained ()

and schedule pane =
  if pane.coalesce_ns = 0 then flush pane
  else if not pane.armed then begin
    let now = now_ns () in
    if now - pane.last_flush >= pane.coalesce_ns then begin
      pane.last_flush <- now;
      flush pane
    end
    else begin
      pane.armed <- true;
      ok "timer"
        (Luv.Timer.start pane.timer (max 1 ((pane.coalesce_ns - (now - pane.last_flush)) / 1_000_000)) pane.on_timer)
    end
  end

let written pane s result _ =
  (match result with Ok () -> () | Error e -> failwith (Luv.Error.strerror e));
  let finish = s.ends.(s.first_end) in
  s.first_end <- (s.first_end + 1) mod max_in_flight;
  s.in_flight <- s.in_flight - 1;
  set_tail pane finish;
  schedule pane

let parse_frames pane =
  let pos = ref 0 and continue = ref true in
  while !continue do
    if !pos + 4 > pane.filled then continue := false
    else
      let len = get_u32 pane.input !pos in
      if !pos + 4 + len > pane.filled then continue := false
      else begin
        let kind = get pane.input (!pos + 4) in
        if kind = layout.full then begin
          let seen = get_u64 pane.input (!pos + 5) in
          if pane.tail > seen then send_tail pane else pane.full_seen <- seen
        end
        else if kind = layout.dead then begin
          pane.dead <- true;
          pane.pane_cpu <- snd (cpu_seconds pane.pid)
        end;
        pane.on_frame kind;
        pos := !pos + 4 + len
      end
  done;
  if !pos > 0 then begin
    Luv.Buffer.blit
      ~source:(Luv.Buffer.sub pane.input ~offset:!pos ~length:(pane.filled - !pos))
      ~destination:(Luv.Buffer.sub pane.input ~offset:0 ~length:(pane.filled - !pos));
    pane.filled <- pane.filled - !pos
  end

let drain_exe () = Filename.concat (Filename.dirname Sys.executable_name) "../bench/drain.exe"

let start ?(samples = 0) ?(observe = false) ?(transcript = false) ?(coalesce_ms = 0) ~variant ~pane_exe ~callbacks ~argv () =
  let ring, control_fd, pid = start_pane pane_exe callbacks in
  let view_fd, drain_fd = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.setsockopt_int view_fd Unix.SO_SNDBUF (1 lsl 20);
  Unix.setsockopt_int drain_fd Unix.SO_RCVBUF (1 lsl 20);
  Unix.set_close_on_exec view_fd;
  let drain = Unix.create_process (drain_exe ()) [| "drain" |] drain_fd Unix.stdout Unix.stderr in
  Unix.close drain_fd;
  let capacity = get_u64 ring 0 in
  let view =
    match variant with
    | Luv_write ->
        let slots = (capacity / layout.record_header) + 1 in
        Stream
          {
            pipe = pipe view_fd;
            headers = Luv.Buffer.create (slots * layout.view_header_max);
            slots;
            next_slot = 0;
            ends = Array.make max_in_flight 0;
            first_end = 0;
            in_flight = 0;
            batch_index = Array.make max_batch 0;
            batch_slot = Array.make max_batch 0;
            batch_header = Array.make max_batch 0;
            batch_len = Array.make max_batch 0;
            sent = 0;
          }
    | Writev ->
        Unix.set_nonblock view_fd;
        let state = Bigarray.Array1.create Bigarray.int64 Bigarray.c_layout 4 in
        Bigarray.Array1.fill state 0L;
        Raw { fd = view_fd; poll = ok "poll" (Luv.Poll.init (Obj.magic view_fd : int)); state; waiting = false }
  in
  let tail_bytes = Bytes.create 13 in
  put_le tail_bytes 0 9 4;
  Bytes.set tail_bytes 4 (Char.chr layout.tail);
  let pane =
    {
      ring;
      capacity;
      control = pipe control_fd;
      view;
      pid;
      input = Luv.Buffer.create (1 lsl 20);
      filled = 0;
      head = 0;
      tail = 0;
      full_seen = -1;
      tail_bytes;
      tail_frame = [ Luv.Buffer.create 13 ];
      records = 0;
      payload = 0;
      reads = 0;
      writes = 0;
      dead = false;
      pane_cpu = 0.;
      observe = observe || samples > 0 || transcript;
      transcript = (if transcript then Some (Buffer.create (8 lsl 20)) else None);
      observed = 0;
      slices = 0;
      latencies = Array.make samples 0;
      samples = 0;
      on_frame = ignore;
      on_drained = ignore;
      coalesce_ns = coalesce_ms * 1_000_000;
      timer = ok "timer" (Luv.Timer.init ());
      armed = false;
      last_flush = 0;
      on_timer = ignore;
      written = (fun _ _ -> ());
      writable = ignore;
    }
  in
  pane.on_timer <-
    (fun () ->
      pane.armed <- false;
      pane.last_flush <- now_ns ();
      flush pane);
  (match view with
  | Stream s -> pane.written <- written pane s
  | Raw r ->
      pane.writable <-
        (fun result ->
          ignore (ok "poll" result : Luv.Poll.Event.t list);
          ok "poll" (Luv.Poll.stop r.poll);
          r.waiting <- false;
          flush pane));
  let allocate _ = Luv.Buffer.sub pane.input ~offset:pane.filled ~length:(Luv.Buffer.size pane.input - pane.filled) in
  Luv.Stream.read_start ~allocate pane.control (function
    | Ok buffer ->
        pane.reads <- pane.reads + 1;
        pane.filled <- pane.filled + Luv.Buffer.size buffer;
        parse_frames pane;
        schedule pane
    | Error `EOF -> ()
    | Error e -> failwith (Luv.Error.strerror e));
  Luv.Stream.write pane.control [ frame layout.init (init_body ~argv) ] (fun r _ -> ok "init" r);
  (pane, drain)

let send pane kind body = Luv.Stream.write pane.control [ frame kind body ] (fun r _ -> ok "send" r)

let finish pane drain =
  send pane layout.exit "";
  (match pane.view with
  | Stream s -> Luv.Handle.close s.pipe ignore
  | Raw r ->
      Luv.Handle.close r.poll ignore;
      Unix.close r.fd);
  Luv.Handle.close pane.timer ignore;
  let deadline = Unix.gettimeofday () +. 5. in
  let timer = ok "timer" (Luv.Timer.init ()) in
  ok "timer"
    (Luv.Timer.start ~repeat:5 timer 5 (fun () ->
         match Unix.waitpid [ Unix.WNOHANG ] pane.pid with
         | 0, _ when Float.(Unix.gettimeofday () < deadline) -> ()
         | 0, _ ->
             Unix.kill pane.pid Sys.sigkill;
             failwith "ko-pane did not exit within 5 s"
         | _ ->
             Luv.Handle.close timer ignore;
             Luv.Handle.close pane.control ignore));
  ignore (Luv.Loop.run () : bool);
  (match Unix.waitpid [] drain with _, Unix.WEXITED 0 -> () | _ -> failwith "drain failed");
  unmap pane.ring

let cpu_self () =
  let t = Unix.times () in
  t.Unix.tms_utime +. t.Unix.tms_stime

let variant_name = function Luv_write -> "luv-write" | Writev -> "writev"

let throughput ~variant ~pane_exe ~produce ~callbacks ~coalesce_ms ~bytes ~streams =
  let pane, drain =
    start ~coalesce_ms ~variant ~pane_exe ~callbacks ~argv:(produce :: string_of_int bytes :: streams) ()
  in
  let started = Unix.gettimeofday () and cpu = cpu_self () in
  let minor = ref 0. and records_at = ref 0 and elapsed = ref 0. and coordinator = ref 0. in
  pane.on_frame <-
    (fun kind ->
      if kind = layout.ready then begin
        minor := Gc.minor_words ();
        records_at := pane.records
      end);
  pane.on_drained <-
    (fun () ->
      if pane.dead && Float.(!elapsed = 0.) then begin
        elapsed := Unix.gettimeofday () -. started;
        coordinator := cpu_self () -. cpu;
        minor := Gc.minor_words () -. !minor;
        Luv.Loop.stop (Luv.Loop.default ())
      end);
  ignore (Luv.Loop.run () : bool);
  finish pane drain;
  let records = pane.records - !records_at in
  Printf.printf
    "ko view=%s callbacks=%b coalesce_ms=%d bytes=%d seconds=%.3f MB/s=%.1f records=%d avg_record=%.0f minor_words/record=%.2f control_reads=%d view_flushes=%d pane_cpu=%.3f coordinator_cpu=%.3f cores=%.2f\n%!"
    (variant_name variant) callbacks coalesce_ms pane.payload !elapsed
    (float_of_int pane.payload /. !elapsed /. 1e6)
    records
    (float_of_int pane.payload /. float_of_int (max 1 records))
    (!minor /. float_of_int (max 1 records))
    pane.reads pane.writes pane.pane_cpu !coordinator
    ((pane.pane_cpu +. !coordinator) /. !elapsed);
  if pane.payload <> bytes then failwith (Printf.sprintf "expected %d bytes, got %d" bytes pane.payload)

let percentile sorted p = sorted.(min (Array.length sorted - 1) (Array.length sorted * p / 100))

let run_until pane condition =
  pane.on_drained <- (fun () -> if condition () then Luv.Loop.stop (Luv.Loop.default ()));
  ignore (Luv.Loop.run () : bool)

let latency ~variant ~pane_exe ~produce ~count ~coalesce_ms =
  let pane, drain =
    start ~samples:count ~coalesce_ms ~variant ~pane_exe ~callbacks:true
      ~argv:[ produce; "--latency"; string_of_int count ] ()
  in
  run_until pane (fun () -> pane.dead);
  finish pane drain;
  let sorted = Array.sub pane.latencies 0 pane.samples in
  Array.sort Int.compare sorted;
  Printf.printf "hop latency view=%s samples=%d p50_us=%.1f p99_us=%.1f max_us=%.1f\n%!" (variant_name variant)
    pane.samples
    (float_of_int (percentile sorted 50) /. 1e3)
    (float_of_int (percentile sorted 99) /. 1e3)
    (float_of_int sorted.(Array.length sorted - 1) /. 1e3)

let snapshots ~variant ~pane_exe ~produce ~lines =
  let pane, drain =
    start ~observe:true ~variant ~pane_exe ~callbacks:true ~argv:[ produce; "--lines"; string_of_int lines ] ()
  in
  run_until pane (fun () -> pane.dead);
  let request ~label ~before ~screen =
    let done_ = ref false in
    pane.on_frame <- (fun kind -> if kind = layout.snapshot_done then done_ := true);
    let slices = pane.slices in
    let started = Unix.gettimeofday () in
    before ();
    let b = Bytes.make 10 '\000' in
    put_le b 0 1 4;
    Bytes.set b 4 (if screen then '\001' else '\000');
    send pane layout.snapshot (Bytes.to_string b);
    run_until pane (fun () -> !done_);
    Printf.printf "snapshot view=%s lines=%d kind=%s bytes=%d ms=%.2f\n%!" (variant_name variant) lines label
      (pane.slices - slices)
      ((Unix.gettimeofday () -. started) *. 1e3)
  in
  request ~label:"full" ~before:ignore ~screen:false;
  request ~label:"screen" ~before:ignore ~screen:true;
  request ~label:"resize+screen"
    ~before:(fun () ->
      let b = Bytes.create 8 in
      List.iteri (fun i v -> put_le b (2 * i) v 2) [ 100; 30; 8; 16 ];
      send pane layout.resize (Bytes.to_string b))
    ~screen:true;
  finish pane drain

let run_program ~variant ~pane_exe ~argv =
  let pane, drain = start ~transcript:true ~variant ~pane_exe ~callbacks:true ~argv () in
  let started = Unix.gettimeofday () in
  run_until pane (fun () -> pane.dead);
  let elapsed = Unix.gettimeofday () -. started in
  finish pane drain;
  let screen =
    Ko_vt.create ~cols:120 ~rows:60 ~scrollback_max_bytes:(1 lsl 20) ~apc_max_bytes:(65 lsl 20)
      ~kitty_image_storage_limit:10_000_000 ~continuation_max_bytes:(65 lsl 20)
  in
  Option.iter (fun b -> Ko_vt.write screen (Buffer.contents b)) pane.transcript;
  print_string (Ko_vt.dump screen Plain);
  Printf.printf "\nrun view=%s bytes=%d seconds=%.3f pane_cpu=%.3f\n%!" (variant_name variant) pane.payload elapsed
    pane.pane_cpu

let cpu_check () =
  let null = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
  let before = Unix.times () in
  let child = Unix.create_process "/usr/bin/yes" [| "yes" |] Unix.stdin null Unix.stderr in
  Unix.sleepf 1.0;
  let raw, converted = cpu_seconds child in
  Unix.kill child Sys.sigkill;
  ignore (Unix.waitpid [] child);
  let after = Unix.times () in
  let children =
    after.Unix.tms_cutime +. after.Unix.tms_cstime -. before.Unix.tms_cutime -. before.Unix.tms_cstime
  in
  Printf.printf "cpu check: proc_pid_rusage as ns=%.3f s, times mach_timebase=%.3f s, getrusage RUSAGE_CHILDREN=%.3f s\n%!"
    raw converted children

let pty_pipe () =
  let master, slave = openpty () in
  let child =
    Unix.create_process "/bin/sh"
      [| "sh"; "-c"; "head -c 1000000 /dev/zero | tr '\\0' x; sleep 0.2" |]
      slave slave Unix.stderr
  in
  Unix.close slave;
  let sizes = ref [] and ending = ref "none" in
  let started = Unix.gettimeofday () in
  (match Luv.Pipe.init () with
  | Error e -> ending := "Pipe.init: " ^ Luv.Error.strerror e
  | Ok pipe -> (
      match Luv.Pipe.open_ pipe (file master) with
      | Error e -> ending := "Pipe.open_: " ^ Luv.Error.strerror e
      | Ok () ->
          Luv.Stream.read_start pipe (function
            | Ok buffer -> sizes := Luv.Buffer.size buffer :: !sizes
            | Error e ->
                ending := Luv.Error.err_name e;
                Luv.Handle.close pipe ignore);
          let timer = ok "timer" (Luv.Timer.init ()) in
          ok "timer"
            (Luv.Timer.start timer 5000 (fun () ->
                 ending := !ending ^ " (deadline)";
                 Luv.Handle.close pipe ignore));
          Luv.Handle.unref timer;
          ignore (Luv.Loop.run () : bool);
          Luv.Handle.close timer ignore;
          ignore (Luv.Loop.run () : bool)));
  ignore (Unix.waitpid [] child);
  let sizes = List.rev !sizes in
  Printf.printf "pty master as Luv.Pipe: reads=%d bytes=%d max_read=%d first_reads=[%s] end=%s seconds=%.3f\n%!"
    (List.length sizes)
    (List.fold_left ( + ) 0 sizes)
    (List.fold_left max 0 sizes)
    (String.concat ";" (List.map string_of_int (List.filteri (fun i _ -> i < 8) sizes)))
    !ending
    (Unix.gettimeofday () -. started)

let allocation () =
  let a, b = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.setsockopt_int a Unix.SO_SNDBUF (1 lsl 20);
  Unix.set_close_on_exec a;
  let drain = Unix.create_process (drain_exe ()) [| "drain" |] b Unix.stdout Unix.stderr in
  Unix.close b;
  let view = pipe a and buffer = Luv.Buffer.create 4096 and count = 20000 in
  let measure label f =
    let before = Gc.minor_words () in
    for _ = 1 to count do
      f ()
    done;
    ignore (Luv.Loop.run () : bool);
    Printf.printf "%s minor_words/call=%.1f\n%!" label ((Gc.minor_words () -. before) /. float_of_int count)
  in
  let written _ _ = () in
  let list = [ buffer ] in
  measure "Luv.Buffer.sub" (fun () -> ignore (Sys.opaque_identity (Luv.Buffer.sub buffer ~offset:13 ~length:64)));
  measure "Luv.Stream.write [sub]" (fun () -> Luv.Stream.write view [ Luv.Buffer.sub buffer ~offset:13 ~length:64 ] written);
  measure "Luv.Stream.write preallocated list" (fun () -> Luv.Stream.write view list written);
  measure "Luv.Stream.try_write preallocated list" (fun () -> ignore (Luv.Stream.try_write view list));
  Luv.Handle.close view ignore;
  ignore (Luv.Loop.run () : bool);
  ignore (Unix.waitpid [] drain)

let () =
  let here = Filename.dirname Sys.executable_name in
  let pane_exe = Filename.concat here "../ko_pane/ko-pane" in
  let produce = Filename.concat here "../bench/produce.exe" in
  let variant = function
    | "luv-write" -> Luv_write
    | "writev" -> Writev
    | other -> invalid_arg ("view variant " ^ other)
  in
  match Array.to_list Sys.argv |> List.tl with
  | "throughput" :: view :: bytes :: callbacks :: coalesce_ms :: streams ->
      throughput ~variant:(variant view) ~pane_exe ~produce ~callbacks:(String.equal callbacks "callbacks")
        ~coalesce_ms:(int_of_string coalesce_ms) ~bytes:(int_of_string bytes) ~streams
  | [ "latency"; view; count; coalesce_ms ] ->
      latency ~variant:(variant view) ~pane_exe ~produce ~count:(int_of_string count)
        ~coalesce_ms:(int_of_string coalesce_ms)
  | [ "snapshot"; view; lines ] -> snapshots ~variant:(variant view) ~pane_exe ~produce ~lines:(int_of_string lines)
  | [ "pty-pipe" ] -> pty_pipe ()
  | [ "allocation" ] -> allocation ()
  | [ "cpu-check" ] -> cpu_check ()
  | "run" :: view :: argv -> run_program ~variant:(variant view) ~pane_exe ~argv
  | _ ->
      prerr_endline
        "usage: coordinator (throughput VIEW BYTES callbacks|no-callbacks COALESCE_MS STREAM... | latency VIEW COUNT \
         COALESCE_MS | snapshot VIEW LINES | pty-pipe | allocation | cpu-check), VIEW is luv-write or writev";
      exit 2
