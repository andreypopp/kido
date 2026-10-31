external read_stub : Unix.file_descr -> Bigstringaf.t -> int -> int -> int = "ko_read" [@@noalloc]
external signal_pipe : Unix.file_descr -> unit = "ko_signal_pipe"
external signal_install : int -> unit = "ko_signal_install"
external signal_take : int -> bool = "ko_signal_take" [@@noalloc]

type interest = Idle | Read | Write | Read_write
type direction = In | Out | Both
type window = { mutable buffer : Bigstringaf.t; mutable off : int; mutable len : int }

type source =
  | Stream of { window : window; on_data : int -> unit; on_end : unit -> unit }
  | Ready of (unit -> unit)

type state = Closed | Parked | Active of { mutable slot : int; mutable direction : direction }

type watch = {
  fd : Unix.file_descr;
  mutable state : state;
  mutable source : source;
  mutable on_writable : unit -> unit;
}

type queued = Stopped | Queued of { mutable index : int }

type timer = {
  callback : unit -> unit;
  mutable due : int;
  mutable repeat : int option;
  mutable queued : queued;
}

type step = Wait | Peek

let interest_of ~read ~write =
  match (read, write) with
  | true, true -> Read_write
  | true, false -> Read
  | false, true -> Write
  | false, false -> Idle

let max_reads = 16
let read_again = -1
let ms = 1_000_000
let stopping = ref false
let closed_watch = { fd = Unix.stdin; state = Closed; source = Ready ignore; on_writable = ignore }
let initial_capacity = 16
let poller = ref (Iomux.Poll.create ~maxfds:initial_capacity ())
let slots = ref (Array.make initial_capacity closed_watch)
let ready = ref (Array.make initial_capacity closed_watch)
let ready_flags = ref (Array.make initial_capacity Iomux.Poll.Flags.empty)
let slot_count = ref 0

let events_of = function
  | In -> Iomux.Poll.Flags.pollin
  | Out -> Iomux.Poll.Flags.pollout
  | Both -> Iomux.Poll.Flags.(pollin + pollout)

let watch fd = { fd; state = Parked; source = Ready ignore; on_writable = ignore }

let handle w source ~on_writable =
  w.source <- source;
  w.on_writable <- on_writable

let fd w = w.fd
let wants_read w = match w.state with Active { direction = In | Both; _ } -> true | _ -> false
let wants_write w = match w.state with Active { direction = Out | Both; _ } -> true | _ -> false

let set_slot w =
  match w.state with
  | Active { slot; direction } -> Iomux.Poll.set_index !poller slot w.fd (events_of direction)
  | Closed | Parked -> ()

let grow () =
  let size = 2 * Array.length !slots in
  let grown = Array.make size closed_watch in
  Array.blit !slots 0 grown 0 !slot_count;
  slots := grown;
  ready := Array.make size closed_watch;
  ready_flags := Array.make size Iomux.Poll.Flags.empty;
  poller := Iomux.Poll.create ~maxfds:size ();
  for i = 0 to !slot_count - 1 do
    set_slot grown.(i)
  done

let activate w direction =
  match w.state with
  | Closed -> ()
  | Active a ->
      if not (Stdlib.( == ) a.direction direction) then begin
        a.direction <- direction;
        set_slot w
      end
  | Parked ->
      if !slot_count = Array.length !slots then grow ();
      !slots.(!slot_count) <- w;
      w.state <- Active { slot = !slot_count; direction };
      incr slot_count;
      set_slot w

let park w =
  match w.state with
  | Closed | Parked -> ()
  | Active { slot; _ } ->
      let last = !slot_count - 1 in
      if slot < last then begin
        let moved = !slots.(last) in
        !slots.(slot) <- moved;
        (match moved.state with Active m -> m.slot <- slot | Closed | Parked -> ());
        set_slot moved
      end;
      Iomux.Poll.invalidate_index !poller last;
      !slots.(last) <- closed_watch;
      slot_count := last;
      w.state <- Parked

let interest w = function
  | Idle -> park w
  | Read -> activate w In
  | Write -> activate w Out
  | Read_write -> activate w Both

let unwatch w =
  park w;
  w.state <- Closed;
  w.source <- Ready ignore;
  w.on_writable <- ignore

let close w =
  unwatch w;
  Unix.close w.fd

let timer_dummy = { callback = ignore; due = 0; repeat = None; queued = Stopped }
let heap = ref (Array.make 16 timer_dummy)
let heap_size = ref 0
let index_of t = match t.queued with Queued { index } -> index | Stopped -> -1

let place t i =
  !heap.(i) <- t;
  match t.queued with Queued q -> q.index <- i | Stopped -> ()

let rec sift_up i =
  if i > 0 then begin
    let parent = (i - 1) / 2 in
    let t = !heap.(i) and p = !heap.(parent) in
    if Int.(t.due < p.due) then begin
      place p i;
      place t parent;
      sift_up parent
    end
  end

let rec sift_down i =
  let left = (2 * i) + 1 in
  if left < !heap_size then begin
    let right = left + 1 in
    let child =
      if right < !heap_size && Int.(!heap.(right).due < !heap.(left).due) then right else left
    in
    let t = !heap.(i) and c = !heap.(child) in
    if Int.(c.due < t.due) then begin
      place c i;
      place t child;
      sift_down child
    end
  end

let timer callback = { callback; due = 0; repeat = None; queued = Stopped }
let is_active t = match t.queued with Queued _ -> true | Stopped -> false

let stop_timer t =
  match t.queued with
  | Stopped -> ()
  | Queued { index = i } ->
      let last = !heap_size - 1 in
      t.queued <- Stopped;
      decr heap_size;
      if i < last then begin
        let moved = !heap.(last) in
        place moved i;
        sift_down i;
        sift_up (index_of moved)
      end;
      !heap.(last) <- timer_dummy

let start_timer t ~after ~repeat =
  stop_timer t;
  t.due <- Native.now () + (after * ms);
  t.repeat <- Option.map (fun r -> r * ms) repeat;
  if !heap_size = Array.length !heap then begin
    let grown = Array.make (2 * !heap_size) timer_dummy in
    Array.blit !heap 0 grown 0 !heap_size;
    heap := grown
  end;
  t.queued <- Queued { index = !heap_size };
  place t !heap_size;
  incr heap_size;
  sift_up (index_of t)

let rec run_timers now =
  if !heap_size > 0 then begin
    let t = !heap.(0) in
    if Int.(t.due <= now) then begin
      (match t.repeat with
      | Some period ->
          t.due <- (if Int.(t.due + period > now) then t.due + period else now + period);
          sift_down 0
      | None -> stop_timer t);
      t.callback ();
      run_timers now
    end
  end

let signals = ref []
let signal_window = { buffer = Bigstringaf.create 4096; off = 0; len = 4096 }

let on_signal signal callback =
  let system = Native.native_signal signal in
  if List.is_empty !signals then begin
    let r, w = Unix.pipe ~cloexec:true () in
    Unix.set_nonblock r;
    Unix.set_nonblock w;
    signal_pipe w;
    let watch = watch r in
    handle watch
      (Stream
         {
           window = signal_window;
           on_data =
             (fun _ ->
               List.iter (fun (system, callback) -> if signal_take system then callback ()) !signals);
           on_end = ignore;
         })
      ~on_writable:ignore;
    interest watch Read
  end;
  signals := (system, callback) :: !signals;
  signal_install system

let rec drain w ~window ~on_data ~on_end reads =
  let len = window.len in
  let n = read_stub w.fd window.buffer window.off len in
  if n > 0 then begin
    on_data n;
    if n = len && reads > 1 && wants_read w then drain w ~window ~on_data ~on_end (reads - 1)
  end
  else if n <> read_again then begin
    interest w (interest_of ~read:false ~write:(wants_write w));
    on_end ()
  end

let dispatch w flags =
  let open Iomux.Poll.Flags in
  let failed = pollerr + pollhup + pollnval in
  if wants_read w && mem flags (pollin + failed) then
    begin match w.source with
    | Stream { window; on_data; on_end } -> drain w ~window ~on_data ~on_end max_reads
    | Ready callback -> callback ()
    end;
  if wants_write w && mem flags (pollout + failed) then w.on_writable ()

let step mode =
  (if !slot_count > 0 || match mode with Wait -> !heap_size > 0 | Peek -> false then
     let timeout : Iomux.Poll.ppoll_timeout =
       match mode with
       | Peek -> Nowait
       | Wait ->
           if !heap_size = 0 then Infinite
           else Nanoseconds (Int64.of_int (max 0 (!heap.(0).due - Native.now ())))
     in
     match Iomux.Poll.ppoll_or_poll !poller !slot_count timeout with
     | exception Unix.Unix_error (Unix.EINTR, _, _) -> ()
     | 0 -> ()
     | found ->
         let poller = !poller and ready = !ready and ready_flags = !ready_flags in
         let n = ref 0 and i = ref 0 in
         while !n < found && !i < !slot_count do
           let flags = Iomux.Poll.get_revents poller !i in
           if Iomux.Poll.Flags.to_int flags <> 0 then begin
             ready.(!n) <- !slots.(!i);
             ready_flags.(!n) <- flags;
             incr n
           end;
           incr i
         done;
         for k = 0 to !n - 1 do
           let w = ready.(k) in
           ready.(k) <- closed_watch;
           dispatch w ready_flags.(k)
         done);
  run_timers (Native.now ())

let stop () = stopping := true

let run () =
  stopping := false;
  while (not !stopping) && (!slot_count > 0 || !heap_size > 0) do
    step Wait
  done

let%test_module "Tests" =
  (module struct
    external signal_deliver : int -> unit = "ko_signal_deliver"

    let%expect_test "step Wait and run return when nothing can wake them" =
      step Wait;
      run ();
      let w = watch (fst (Unix.pipe ())) in
      handle w (Ready ignore) ~on_writable:ignore;
      step Wait;
      run ();
      unwatch w;
      print_endline "returned";
      [%expect {| returned |}]

    let%expect_test "timers fire in due order, repeat and cancel" =
      let log = ref [] in
      let note name () = log := name :: !log in
      let late = timer (note "late") and early = timer (note "early") in
      let repeating = timer (note "tick") and cancelled = timer (note "cancelled") in
      start_timer late ~after:12 ~repeat:None;
      start_timer early ~after:3 ~repeat:None;
      start_timer repeating ~after:5 ~repeat:(Some 5);
      start_timer cancelled ~after:1 ~repeat:None;
      stop_timer cancelled;
      let deadline = Native.now () + (500 * ms) in
      while List.length (List.filter (String.equal "tick") !log) < 3 && Native.now () < deadline do
        step Wait
      done;
      stop_timer repeating;
      Printf.printf "%s\nactive: %b %b\n"
        (String.concat " " (List.rev !log))
        (is_active late) (is_active repeating);
      [%expect {|
        early tick tick late tick
        active: false false |}]

    let%expect_test "a stream reads up to the bound per step and reports the end once" =
      let a, b = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      Unix.set_nonblock a;
      let window = { buffer = Bigstringaf.create 4; off = 0; len = 4 } in
      let reads = ref 0 and ends = ref 0 in
      let w = watch a in
      handle w
        (Stream { window; on_data = (fun _ -> incr reads); on_end = (fun () -> incr ends) })
        ~on_writable:ignore;
      ignore (Unix.write_substring b (String.make 100 'x') 0 100 : int);
      interest w Read;
      step Peek;
      Printf.printf "after one step: %d reads\n" !reads;
      step Peek;
      step Peek;
      Printf.printf "after three: %d reads\n" !reads;
      Unix.close b;
      step Peek;
      step Peek;
      Printf.printf "reads %d, ends %d\n" !reads !ends;
      unwatch w;
      Unix.close a;
      [%expect
        {|
        after one step: 16 reads
        after three: 25 reads
        reads 25, ends 1 |}]

    let%expect_test "an unwatched watch and what its callbacks capture can be collected" =
      let weak = Weak.create 1 and weak_watch = Weak.create 1 in
      let r, w = Unix.pipe () in
      let other_r, other_w = Unix.pipe () in
      let keep = watch other_r in
      handle keep (Ready ignore) ~on_writable:ignore;
      interest keep Read;
      (let payload = Bytes.create 100 in
       let victim = watch r in
       Weak.set weak 0 (Some payload);
       Weak.set weak_watch 0 (Some victim);
       handle victim
         (Stream
            {
              window = { buffer = Bigstringaf.create 8; off = 0; len = 8 };
              on_data = (fun _ -> ignore (Bytes.length payload));
              on_end = ignore;
            })
         ~on_writable:(fun () -> ignore (Bytes.length payload));
       interest victim Read;
       ignore (Unix.write_substring w "x" 0 1 : int);
       step Peek;
       unwatch victim);
      Gc.full_major ();
      Printf.printf "payload collected %b, watch collected %b\n"
        (not (Weak.check weak 0))
        (not (Weak.check weak_watch 0));
      unwatch keep;
      List.iter Unix.close [ r; w; other_r; other_w ];
      [%expect {| payload collected true, watch collected true |}]

    let%expect_test "watches added during a dispatch do not hide the rest of the batch" =
      let pipes = List.init 2 (fun _ -> Unix.pipe ()) in
      let ran = ref [] in
      let extra = ref [] in
      let watches =
        List.mapi
          (fun i (r, w) ->
            ignore (Unix.write_substring w "x" 0 1 : int);
            let me = watch r in
            handle me
              (Ready
                 (fun () ->
                   ran := i :: !ran;
                   interest me Idle;
                   if i = 0 then
                     for _ = 1 to 100 do
                       let r, w = Unix.pipe () in
                       let added = watch r in
                       interest added Read;
                       let added = (added, w) in
                       extra := added :: !extra
                     done))
              ~on_writable:ignore;
            interest me Read;
            me)
          pipes
      in
      step Peek;
      Printf.printf "ran %s\n"
        (String.concat " " (List.map string_of_int (List.sort Int.compare !ran)));
      List.iter
        (fun (w, peer) ->
          close w;
          Unix.close peer)
        !extra;
      List.iter unwatch watches;
      List.iter
        (fun (r, w) ->
          Unix.close r;
          Unix.close w)
        pipes;
      [%expect {| ran 0 1 |}]

    let%expect_test "a signal that arrives with a full pipe is not lost, and runs once per wakeup" =
      let first = ref 0 and second = ref 0 in
      on_signal Sys.sigusr1 (fun () -> incr first);
      on_signal Sys.sigusr2 (fun () -> incr second);
      for _ = 1 to 200_000 do
        signal_deliver (Native.native_signal Sys.sigusr1)
      done;
      signal_deliver (Native.native_signal Sys.sigusr2);
      step Peek;
      Printf.printf "usr1 %d, usr2 %d\n" !first !second;
      step Peek;
      Printf.printf "usr1 %d, usr2 %d\n" !first !second;
      [%expect {|
        usr1 1, usr2 1
        usr1 1, usr2 1 |}]
  end)
