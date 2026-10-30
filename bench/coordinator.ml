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
  mutable bytes : int;
  mutable records : int;
  mutable dead : bool;
  mutable samples : float list option;
  transcript : Buffer.t option;
}

let start ~pane_exe ~callbacks ~argv ~transcript ~latency =
  let config =
    {
      Config.dir = "/tmp";
      pane_exe;
      terminfo = "/tmp";
      shell = "/bin/sh";
      terminal = Config.limits ();
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
    Pane_proc.create ~callbacks config ~id:"pane_1" ~cwd:"/" ~argv ~env:[ "TERM=xterm-ghostty" ]
  in
  let p =
    {
      proc;
      view = Connection.writer fd;
      drain;
      pos = 0;
      bytes = 0;
      records = 0;
      dead = false;
      samples = (if latency then Some [] else None);
      transcript = (if transcript then Some (Buffer.create 4096) else None);
    }
  in
  Pane_proc.listen proc (function
    | Record record -> (
        match record.data with
        | Bytes ->
            p.bytes <- p.bytes + record.len;
            p.records <- p.records + 1;
            (match p.samples with
            | None -> ()
            | Some samples ->
                let now = Uv.now () in
                let found = ref samples in
                let text =
                  Bigstringaf.substring (Pane_proc.buffer proc) ~off:record.at ~len:record.len
                in
                for i = 0 to String.length text - 21 do
                  if Char.equal text.[i] 'T' then
                    match int_of_string_opt (String.sub text (i + 1) 20) with
                    | Some ts -> found := (float (now - ts) /. 1e3) :: !found
                    | None -> ()
                done;
                p.samples <- Some !found);
            Option.iter
              (fun b ->
                Buffer.add_string b
                  (Bigstringaf.substring (Pane_proc.buffer proc) ~off:record.at ~len:record.len))
              p.transcript
        | Dead_marker _ -> p.dead <- true
        | _ -> ())
    | Failed dead -> failwith (Option.value ~default:"pane failed" dead.error)
    | _ -> ());
  p

let flush p =
  ignore (Pane_proc.scan p.proc : bool);
  if Connection.available p.view then
    Pane_proc.iter_from p.proc p.pos (fun record ->
        match record.data with
        | Bytes -> (
            match
              Connection.record p.view ~queue:false ~kind:1 ~offset:record.offset
                (Pane_proc.buffer p.proc) ~at:record.at ~len:record.len
            with
            | Accepted ->
                p.pos <- record.next;
                true
            | Blocked accepted ->
                if accepted then p.pos <- record.next;
                false
            | Closed -> failwith "view closed")
        | _ ->
            p.pos <- record.next;
            true)

let drained p = Connection.available p.view && p.pos >= Pane_proc.position p.proc

let finish p =
  Connection.close p.view;
  Pane_proc.shutdown p.proc;
  run_until ~timeout:5. (fun () -> Pane_proc.finished p.proc) (fun () -> Pane_proc.reap p.proc);
  ignore (Luv.Loop.run ~mode:`NOWAIT () : bool);
  match Unix.waitpid [] p.drain with _, Unix.WEXITED 0 -> () | _ -> failwith "drain failed"

let throughput ~pane_exe ~produce ~bytes ~callbacks ~coalesce_ms ~streams =
  if coalesce_ms <> 2 then invalid_arg "production coalescing is 2 ms";
  let p =
    start ~pane_exe ~callbacks
      ~argv:(produce :: string_of_int bytes :: streams)
      ~transcript:false ~latency:false
  in
  let started = Unix.gettimeofday () and cpu = cpu_self () and words = Gc.minor_words () in
  run_until ~timeout:120. (fun () -> p.dead && drained p) (fun () -> flush p);
  let elapsed = Unix.gettimeofday () -. started and used = cpu_self () -. cpu in
  let pane_cpu = snd (cpu_seconds (Pane_proc.child_pid p.proc)) in
  Printf.printf
    "ko view=writev callbacks=%b coalesce_ms=%d bytes=%d seconds=%.3f MB/s=%.1f records=%d \
     minor_words/record=%.2f pane_cpu=%.3f coordinator_cpu=%.3f cores=%.2f\n\
     %!"
    callbacks coalesce_ms p.bytes elapsed
    (float p.bytes /. elapsed /. 1e6)
    p.records
    ((Gc.minor_words () -. words) /. float (max 1 p.records))
    pane_cpu used
    ((pane_cpu +. used) /. elapsed);
  finish p;
  if p.bytes <> bytes then failwith "byte count mismatch"

let snapshots ~pane_exe ~produce ~lines =
  let p =
    start ~pane_exe ~callbacks:true
      ~argv:[ produce; "--lines"; string_of_int lines ]
      ~transcript:false ~latency:false
  in
  run_until ~timeout:120. (fun () -> p.dead && drained p) (fun () -> flush p);
  let request label full before =
    before ();
    let finished = ref false and total = ref 0 in
    let started = Unix.gettimeofday () in
    Pane_proc.snapshot p.proc ~full
      ~consume:(fun record ->
        total := !total + record.len - 2;
        ignore
          (Connection.record p.view ~queue:true ~kind:2 ~offset:record.offset
             (Pane_proc.buffer p.proc) ~at:record.at ~len:record.len))
      ~done_:(function Ok () -> finished := true | Error message -> failwith message);
    run_until ~timeout:120. (fun () -> !finished && Connection.available p.view) (fun () -> flush p);
    Printf.printf "snapshot view=writev lines=%d kind=%s bytes=%d ms=%.2f\n%!" lines label !total
      ((Unix.gettimeofday () -. started) *. 1e3)
  in
  request "full" true ignore;
  request "screen" false ignore;
  request "resize+screen" false (fun () ->
      let b = Buffer.create 8 in
      Pane_proc.size b { Config.cols = 100; rows = 30; cell_w_px = 8; cell_h_px = 16 };
      Pane_proc.send p.proc Resize (Buffer.contents b));
  finish p

let latency ~pane_exe ~produce ~count =
  let p =
    start ~pane_exe ~callbacks:true
      ~argv:[ produce; "--latency"; string_of_int count ]
      ~transcript:true ~latency:true
  in
  run_until ~timeout:120. (fun () -> p.dead && drained p) (fun () -> flush p);
  let a = Array.of_list (List.sort Float.compare (Option.value ~default:[] p.samples)) in
  if Array.length a > 0 then
    Printf.printf "hop latency view=writev samples=%d p50_us=%.1f p99_us=%.1f max_us=%.1f\n%!"
      (Array.length a)
      a.(Array.length a / 2)
      a.(Array.length a * 99 / 100)
      a.(Array.length a - 1);
  finish p

let run_program ~pane_exe ~argv =
  let p = start ~pane_exe ~callbacks:true ~argv ~transcript:true ~latency:false in
  run_until ~timeout:900. (fun () -> p.dead && drained p) (fun () -> flush p);
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
  Unix.kill child Sys.sigkill;
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
          Luv.Stream.read_start pipe (function
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

let () =
  let here = Filename.dirname (Unix.realpath Sys.executable_name) in
  let pane_exe = Filename.concat here "../ko_pane/ko-pane"
  and produce = Filename.concat here "produce.exe" in
  match Array.to_list Sys.argv |> List.tl with
  | "throughput" :: "writev" :: bytes :: callbacks :: coalesce_ms :: streams ->
      throughput ~pane_exe ~produce ~bytes:(int_of_string bytes)
        ~callbacks:(String.equal callbacks "callbacks")
        ~coalesce_ms:(int_of_string coalesce_ms) ~streams
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
