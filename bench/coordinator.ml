open Ko_server

external openpty : unit -> Unix.file_descr * Unix.file_descr = "ko_spike_pty"
external cpu_seconds : int -> float * float = "ko_spike_cpu_seconds"

let drain_exe () = Filename.concat (Filename.dirname Sys.executable_name) "drain.exe"

let cpu_self () =
  let t = Unix.times () in
  t.Unix.tms_utime +. t.tms_stime

let run_until ~timeout condition work =
  let timer = Uv.ok (Luv.Timer.init ()) in
  let deadline = Unix.gettimeofday () +. timeout in
  Uv.ok
    (Luv.Timer.start ~repeat:2 timer 0 (fun () ->
         work ();
         if condition () then Luv.Loop.stop (Luv.Loop.default ())
         else if Float.(Unix.gettimeofday () > deadline) then failwith "benchmark deadline"));
  ignore (Luv.Loop.run () : bool);
  Luv.Handle.close timer ignore

type pane = {
  proc : Pane_proc.t;
  view : Connection.t;
  drain : int;
  mutable pos : int;
  mutable counted : int;
  mutable bytes : int;
  mutable records : int;
  mutable samples : float list option;
  transcript : Buffer.t option;
}

let start ~pane_exe ~argv ~transcript ~latency =
  let config =
    {
      Config.dir = "/tmp";
      socket = "/tmp/socket";
      pane_exe;
      terminfo = "/tmp";
      shell = "/bin/sh";
      limits = Config.default_limits;
      env = [];
      cwd = "/";
    }
  in
  let fd, other = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.setsockopt_int fd Unix.SO_SNDBUF (1 lsl 20);
  Unix.setsockopt_int other Unix.SO_RCVBUF (1 lsl 20);
  Unix.set_close_on_exec fd;
  let drain = Unix.create_process (drain_exe ()) [| "drain" |] other Unix.stdout Unix.stderr in
  Unix.close other;
  let proc =
    Pane_proc.create config ~id:(Ids.Pane_id.make 1) ~cwd:"/" ~argv ~env:[ "TERM=xterm-ghostty" ]
      ~notify:(function
      | Dead { cause = Failed message; _ } -> failwith message
      | Title | Pwd | Output | Dead _ -> ())
  in
  let p =
    {
      proc;
      view = Connection.writer fd;
      drain;
      pos = 0;
      counted = 0;
      bytes = 0;
      records = 0;
      samples = (if latency then Some [] else None);
      transcript = (if transcript then Some (Buffer.create 4096) else None);
    }
  in
  p

let lost = ref 0

let count_records ring counted ~on_bytes =
  let upper = Ring.head ring in
  if !counted < Ring.tail ring then (
    incr lost;
    counted := Ring.tail ring);
  while !counted < upper do
    let pos = !counted in
    (match Ring.kind ring pos with Bytes -> on_bytes pos | Marker | Slice | Pad -> ());
    counted := Ring.next ring pos
  done

let count p =
  let ring = Pane_proc.ring p.proc in
  let counted = ref p.counted in
  count_records ring counted ~on_bytes:(fun pos ->
      let at = Ring.at ring pos and len = Ring.length ring pos in
      p.bytes <- p.bytes + len;
      p.records <- p.records + 1;
      (match p.samples with
      | None -> ()
      | Some samples ->
          let now = Uv.now () in
          let found = ref samples in
          let text = Bigstringaf.substring (Ring.buffer ring) ~off:at ~len in
          for i = 0 to String.length text - 21 do
            if Char.equal text.[i] 'T' then
              match int_of_string_opt (String.sub text (i + 1) 20) with
              | Some ts -> found := (float (now - ts) /. 1e3) :: !found
              | None -> ()
          done;
          p.samples <- Some !found);
      match p.transcript with
      | None -> ()
      | Some b -> Buffer.add_string b (Bigstringaf.substring (Ring.buffer ring) ~off:at ~len));
  p.counted <- !counted

let nexts = Array.make Connection.batch_capacity 0

let flush p =
  ignore (Pane_proc.scan p.proc : bool);
  count p;
  let ring = Pane_proc.ring p.proc in
  let upper = Ring.head ring in
  if p.pos < Ring.tail ring then failwith "the benchmark view fell behind the ring";
  let send () =
    let count = Connection.batch_count p.view in
    if count = 0 then true
    else
      let accepted = Connection.batch_send p.view (Ring.buffer ring) in
      if accepted < 0 then failwith "view closed";
      if accepted > 0 then p.pos <- nexts.(accepted - 1);
      accepted = count
  in
  if Connection.available p.view then begin
    let pos = ref p.pos and go = ref true in
    while !go && !pos < upper do
      let here = !pos in
      let next = Ring.next ring here in
      (match Ring.kind ring here with
      | Bytes ->
          nexts.(Connection.batch_count p.view) <- next;
          Connection.batch_add p.view ~offset:(Ring.offset ring here) ~at:(Ring.at ring here)
            ~len:(Ring.length ring here);
          if Connection.batch_full p.view then go := send ()
      | Marker | Slice | Pad -> if Connection.batch_count p.view = 0 then p.pos <- next);
      pos := next
    done;
    if !go && send () then p.pos <- upper
  end

let dead p = Option.is_some (Pane_proc.dead p.proc)
let drained p = Connection.available p.view && p.pos >= Ring.head (Pane_proc.ring p.proc)

let finish p =
  Connection.close p.view;
  Pane_proc.shutdown p.proc;
  run_until ~timeout:5.
    (fun () -> match Pane_proc.life p.proc with Reaped -> true | Open | Closed -> false)
    (fun () -> Pane_proc.reap p.proc);
  ignore (Luv.Loop.run ~mode:`NOWAIT () : bool);
  match Unix.waitpid [] p.drain with _, Unix.WEXITED 0 -> () | _ -> failwith "drain failed"

let throughput ~pane_exe ~produce ~bytes ~coalesce_ms ~streams =
  if coalesce_ms <> 2 then invalid_arg "production coalescing is 2 ms";
  let p =
    start ~pane_exe
      ~argv:(produce :: string_of_int bytes :: streams)
      ~transcript:false ~latency:false
  in
  let started = Unix.gettimeofday () and cpu = cpu_self () and words = Gc.minor_words () in
  run_until ~timeout:120. (fun () -> dead p && drained p) (fun () -> flush p);
  let elapsed = Unix.gettimeofday () -. started and used = cpu_self () -. cpu in
  let pane_cpu = snd (cpu_seconds (Pid.to_int (Pane_proc.pid p.proc))) in
  Printf.printf
    "ko view=writev coalesce_ms=%d bytes=%d seconds=%.3f MB/s=%.1f records=%d \
     minor_words/record=%.2f pane_cpu=%.3f coordinator_cpu=%.3f cores=%.2f\n\
     %!"
    coalesce_ms p.bytes elapsed
    (float p.bytes /. elapsed /. 1e6)
    p.records
    ((Gc.minor_words () -. words) /. float (max 1 p.records))
    pane_cpu used
    ((pane_cpu +. used) /. elapsed);
  finish p;
  if !lost > 0 || p.bytes <> bytes then failwith "byte count mismatch"

let snapshots ~pane_exe ~produce ~lines =
  let p =
    start ~pane_exe
      ~argv:[ produce; "--lines"; string_of_int lines ]
      ~transcript:false ~latency:false
  in
  run_until ~timeout:120. (fun () -> dead p && drained p) (fun () -> flush p);
  let request label history before =
    before ();
    let finished = ref false and total = ref 0 in
    let started = Unix.gettimeofday () in
    Pane_proc.snapshot p.proc ~history
      ~consume:(fun pos ->
        let ring = Pane_proc.ring p.proc in
        total := !total + Ring.length ring pos - Protocol.Record.slice_size;
        ignore
          (Connection.record p.view ~queue:true ~kind:Snapshot ~offset:(Ring.offset ring pos)
             (Ring.buffer ring) ~at:(Ring.at ring pos) ~len:(Ring.length ring pos)))
      ~done_:(function Ok () -> finished := true | Error message -> failwith message);
    run_until ~timeout:120. (fun () -> !finished && Connection.available p.view) (fun () -> flush p);
    Printf.printf "snapshot view=writev lines=%d kind=%s bytes=%d ms=%.2f\n%!" lines label !total
      ((Unix.gettimeofday () -. started) *. 1e3)
  in
  request "full" History_all ignore;
  request "screen" History_none ignore;
  request "resize+screen" History_none (fun () ->
      Pane_proc.resize p.proc
        { Protocol.cols = 100; rows = 30; cell_px = Some { width = 8; height = 16 } });
  finish p

let latency ~pane_exe ~produce ~count =
  let p =
    start ~pane_exe
      ~argv:[ produce; "--latency"; string_of_int count ]
      ~transcript:true ~latency:true
  in
  run_until ~timeout:120. (fun () -> dead p && drained p) (fun () -> flush p);
  let a = Array.of_list (List.sort Float.compare (Option.value ~default:[] p.samples)) in
  if Array.length a > 0 then
    Printf.printf "hop latency view=writev samples=%d p50_us=%.1f p99_us=%.1f max_us=%.1f\n%!"
      (Array.length a)
      a.(Array.length a / 2)
      a.(Array.length a * 99 / 100)
      a.(Array.length a - 1);
  finish p

let run_program ~pane_exe ~argv =
  let p = start ~pane_exe ~argv ~transcript:true ~latency:false in
  run_until ~timeout:900. (fun () -> dead p && drained p) (fun () -> flush p);
  let vt = Bench_terminal.create ~scrollback_max_bytes:(1 lsl 20) ~cols:120 ~rows:60 () in
  Option.iter (fun b -> Ko_vt.write vt (Buffer.contents b)) p.transcript;
  print_endline (Ko_vt.dump vt Plain);
  finish p

let cpu_check () =
  let null = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
  let before = Unix.times () in
  let child = Unix.create_process "/usr/bin/yes" [| "yes" |] Unix.stdin null Unix.stderr in
  Unix.sleepf 1.0;
  let raw, converted = cpu_seconds child in
  ignore (Pid.signal (Option.get (Pid.of_int child)) Sys.sigkill : (unit, Unix.error) result);
  ignore (Unix.waitpid [] child);
  let after = Unix.times () in
  let children =
    after.Unix.tms_cutime +. after.Unix.tms_cstime -. before.Unix.tms_cutime
    -. before.Unix.tms_cstime
  in
  Printf.printf
    "cpu check: proc_pid_rusage as ns=%.3f s, times mach_timebase=%.3f s, getrusage \
     RUSAGE_CHILDREN=%.3f s\n\
     %!"
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
      match Luv.Pipe.open_ pipe (Uv.file master) with
      | Error e -> ending := "Pipe.open_: " ^ Luv.Error.strerror e
      | Ok () ->
          Uv.read_start pipe (function
            | Ok buffer -> sizes := Luv.Buffer.size buffer :: !sizes
            | Error e ->
                ending := Luv.Error.err_name e;
                Luv.Handle.close pipe ignore);
          let timer = Uv.ok (Luv.Timer.init ()) in
          Uv.ok
            (Luv.Timer.start timer 5000 (fun () ->
                 ending := !ending ^ " (deadline)";
                 Luv.Handle.close pipe ignore));
          Luv.Handle.unref timer;
          ignore (Luv.Loop.run () : bool);
          Luv.Handle.close timer ignore;
          ignore (Luv.Loop.run () : bool)));
  ignore (Unix.waitpid [] child);
  let sizes = List.rev !sizes in
  Printf.printf
    "pty master as Luv.Pipe: reads=%d bytes=%d max_read=%d first_reads=[%s] end=%s seconds=%.3f\n%!"
    (List.length sizes) (List.fold_left ( + ) 0 sizes) (List.fold_left max 0 sizes)
    (String.concat ";" (List.map string_of_int (List.filteri (fun i _ -> i < 8) sizes)))
    !ending
    (Unix.gettimeofday () -. started)

let allocation () =
  let a, b = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.setsockopt_int a Unix.SO_SNDBUF (1 lsl 20);
  Unix.set_close_on_exec a;
  let drain = Unix.create_process (drain_exe ()) [| "drain" |] b Unix.stdout Unix.stderr in
  Unix.close b;
  let view = Uv.ok (Luv.Pipe.init ()) in
  Uv.ok (Luv.Pipe.open_ view (Uv.file a));
  let buffer = Luv.Buffer.create 4096 and count = 20000 in
  let measure label f =
    let before = Gc.minor_words () in
    for _ = 1 to count do
      f ()
    done;
    ignore (Luv.Loop.run () : bool);
    Printf.printf "%s minor_words/call=%.1f\n%!" label
      ((Gc.minor_words () -. before) /. float_of_int count)
  in
  let written _ _ = () in
  let list = [ buffer ] in
  measure "Luv.Buffer.sub" (fun () ->
      ignore (Sys.opaque_identity (Luv.Buffer.sub buffer ~offset:13 ~length:64)));
  measure "Luv.Stream.write [sub]" (fun () ->
      Luv.Stream.write view [ Luv.Buffer.sub buffer ~offset:13 ~length:64 ] written);
  measure "Luv.Stream.write preallocated list" (fun () -> Luv.Stream.write view list written);
  measure "Luv.Stream.try_write preallocated list" (fun () ->
      ignore (Luv.Stream.try_write view list));
  Luv.Handle.close view ignore;
  ignore (Luv.Loop.run () : bool);
  ignore (Unix.waitpid [] drain)

let flood ~pane_exe ~produce ~panes ~views ~bytes ~window ~streams =
  let config =
    {
      Config.dir = "/tmp";
      socket = "/tmp/socket";
      pane_exe;
      terminfo = "/tmp";
      shell = "/bin/sh";
      limits = Config.default_limits;
      env = [];
      cwd = "/";
    }
  in
  let here = Filename.dirname Sys.executable_name in
  let timer = Uv.ok (Luv.Timer.init ()) in
  let tick = ref ignore in
  let finished = ref false in
  let state =
    State.create config ~activity:(fun () ->
        (not !finished)
        && (not (Luv.Handle.is_active timer))
        && begin
          Uv.ok (Luv.Timer.start ~repeat:window timer window (fun () -> !tick ()));
          true
        end)
  in
  let set = State.panes state in
  let null = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
  let deaths = Hashtbl.create 32 in
  let started = ref 0. in
  let spawn ~label ~command ~view =
    let pane =
      match
        Panes.add set { Protocol.Request.cwd = Some "/"; command = Some (Argv command); env = [] }
          ~notify:(fun id event ->
            State.event state id event;
            match event with
            | Dead _ ->
                Hashtbl.replace deaths (Ids.Pane_id.to_string id) (Unix.gettimeofday () -. !started)
            | Title | Pwd | Output -> ())
      with
      | Ok pane -> pane
      | Error message -> failwith message
    in
    ( pane,
      if view then begin
        let fd, other = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
        Unix.setsockopt_int fd Unix.SO_SNDBUF (1 lsl 20);
        Unix.setsockopt_int other Unix.SO_RCVBUF (1 lsl 20);
        Unix.set_close_on_exec fd;
        let reader =
          match label with
          | Some label ->
              let exe = Filename.concat here "latency_drain.exe" in
              Unix.create_process exe [| exe; label |] other Unix.stdout Unix.stderr
          | None -> Unix.create_process (drain_exe ()) [| "drain" |] other Unix.stdout null
        in
        Unix.close other;
        let connection = Connection.writer fd in
        State.add_view state
          (View.create pane connection ~client:None ~offset:None ~history:History_none);
        Some (connection, reader)
      end
      else None )
  in
  let streams_command stamped =
    (produce :: (if stamped then [ "--stamped" ] else [])) @ (string_of_int bytes :: streams)
  in
  let flooded =
    List.init panes (fun i ->
        spawn
          ~label:(if i = 0 then Some "flood" else None)
          ~command:(streams_command (i = 0))
          ~view:(i < views))
  in
  let quiet = spawn ~label:(Some "echo") ~command:[ "/bin/cat" ] ~view:true in
  let flood_panes = List.map fst flooded in
  let counters = List.map (fun pane -> (pane, ref 0, ref 0)) flood_panes in
  let tick_body () =
    let produced = ref false in
    Panes.iter set (fun pane -> if Pane_proc.scan (Pane.proc pane) then produced := true);
    List.iter
      (fun (pane, counted, records) ->
        count_records (Pane_proc.ring (Pane.proc pane)) counted ~on_bytes:(fun _ -> incr records))
      counters;
    State.pump state;
    let idle = (not !produced) && not (State.waiting state) in
    if idle then Uv.ok (Luv.Timer.stop timer);
    if
      idle
      && List.for_all (fun pane -> Option.is_some (Pane_proc.dead (Pane.proc pane))) flood_panes
    then (
      finished := true;
      Luv.Loop.stop (Luv.Loop.default ()))
  in
  tick := tick_body;
  let echo = Uv.ok (Luv.Timer.init ()) in
  let quiet_pane, _ = quiet in
  Uv.ok
    (Luv.Timer.start ~repeat:10 echo 10 (fun () ->
         if not !finished then
           ignore
             (Pane_proc.input (Pane.proc quiet_pane)
                (Text (Base64.encode_exn (Printf.sprintf "T%020d\n" (Uv.now ()))))
                ignore)));
  let watchdog = Uv.ok (Luv.Timer.init ()) in
  Uv.ok (Luv.Timer.start watchdog 120_000 (fun () -> failwith "benchmark deadline"));
  Runtime_events.start ();
  let cursor = Runtime_events.create_cursor None in
  let gc_ns = ref 0L and begun = Hashtbl.create 4 in
  let phase_key = function
    | Runtime_events.EV_MINOR -> Some 0
    | EV_MAJOR_SLICE -> Some 1
    | _ -> None
  in
  let callbacks =
    Runtime_events.Callbacks.create
      ~runtime_begin:(fun _ ts phase ->
        Option.iter
          (fun key -> Hashtbl.replace begun key (Runtime_events.Timestamp.to_int64 ts))
          (phase_key phase))
      ~runtime_end:(fun _ ts phase ->
        Option.iter
          (fun key ->
            Option.iter
              (fun start ->
                gc_ns := Int64.add !gc_ns (Int64.sub (Runtime_events.Timestamp.to_int64 ts) start))
              (Hashtbl.find_opt begun key))
          (phase_key phase))
      ()
  in
  let poll = Uv.ok (Luv.Timer.init ()) in
  Uv.ok
    (Luv.Timer.start ~repeat:50 poll 50 (fun () ->
         ignore (Runtime_events.read_poll cursor callbacks None : int)));
  started := Unix.gettimeofday ();
  let cpu = cpu_self () and words = Gc.minor_words () in
  tick_body ();
  ignore (Luv.Loop.run () : bool);
  let elapsed = Unix.gettimeofday () -. !started and used = cpu_self () -. cpu in
  let words = Gc.minor_words () -. words in
  ignore (Runtime_events.read_poll cursor callbacks None : int);
  let total =
    List.fold_left
      (fun sum (pane, _, _) -> sum + Ring.end_offset (Pane_proc.ring (Pane.proc pane)))
      0 counters
  in
  let records = List.fold_left (fun sum (_, _, records) -> sum + !records) 0 counters in
  let rates =
    List.map
      (fun (pane, _, _) ->
        let id = Ids.Pane_id.to_string (Pane.id pane) in
        float (Ring.end_offset (Pane_proc.ring (Pane.proc pane)))
        /. Option.value ~default:elapsed (Hashtbl.find_opt deaths id)
        /. 1e6)
      counters
  in
  let lowest = List.fold_left Float.min infinity rates
  and highest = List.fold_left Float.max 0. rates in
  if !lost > 0 then failwith "the benchmark counter fell behind the ring";
  Printf.printf
    "flood panes=%d views=%d window_ms=%d bytes_per_pane=%d seconds=%.2f total_MBps=%.1f \
     pane_MBps_min=%.1f pane_MBps_max=%.1f coordinator_cores=%.2f records=%d \
     minor_words_per_record=%.2f gc_pct_of_cpu=%.1f\n\
     %!"
    panes views window bytes elapsed
    (float total /. elapsed /. 1e6)
    lowest highest (used /. elapsed) records
    (words /. float (max 1 records))
    (Int64.to_float !gc_ns /. 1e9 /. used *. 100.);
  List.iter (fun handle -> Luv.Handle.close handle ignore) [ echo; poll; watchdog; timer ];
  let wired = List.filter_map snd (quiet :: flooded) in
  List.iter (fun (connection, _) -> Connection.close connection) wired;
  for _ = 1 to 3 do
    ignore (Luv.Loop.run ~mode:`NOWAIT () : bool)
  done;
  List.iter (fun (_, reader) -> ignore (Unix.waitpid [] reader)) wired;
  Panes.shutdown set;
  run_until ~timeout:10.
    (fun () ->
      Panes.reap set;
      List.for_all
        (fun (pane, _) ->
          match Pane_proc.life (Pane.proc pane) with Reaped -> true | Open | Closed -> false)
        (quiet :: flooded))
    ignore

let () =
  let here = Filename.dirname (Unix.realpath Sys.executable_name) in
  let pane_exe = Filename.concat here "../ko_pane/ko-pane"
  and produce = Filename.concat here "produce.exe" in
  match Array.to_list Sys.argv |> List.tl with
  | "throughput" :: "writev" :: bytes :: coalesce_ms :: streams ->
      throughput ~pane_exe ~produce ~bytes:(int_of_string bytes)
        ~coalesce_ms:(int_of_string coalesce_ms) ~streams
  | "flood" :: panes :: views :: bytes :: window :: streams ->
      flood ~pane_exe ~produce ~panes:(int_of_string panes) ~views:(int_of_string views)
        ~bytes:(int_of_string bytes) ~window:(int_of_string window) ~streams
  | [ "latency"; "writev"; count; "2" ] -> latency ~pane_exe ~produce ~count:(int_of_string count)
  | [ "snapshot"; "writev"; lines ] -> snapshots ~pane_exe ~produce ~lines:(int_of_string lines)
  | [ "pty-pipe" ] -> pty_pipe ()
  | [ "allocation" ] -> allocation ()
  | [ "cpu-check" ] -> cpu_check ()
  | "run" :: "writev" :: argv -> run_program ~pane_exe ~argv
  | _ ->
      prerr_endline
        "usage: coordinator throughput|latency|snapshot|run writev ... | \
         pty-pipe|allocation|cpu-check";
      exit 2
