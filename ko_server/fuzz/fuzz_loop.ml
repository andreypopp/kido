let%test_module "Tests" =
  (module struct
    open Ko_server

    type kind = Socket | Pipe

    type op =
      | Interest of int * Event_loop.interest
      | Window of int * int * int
      | Send of int * int
      | Fill of int
      | Drain_peer of int
      | Close_peer of int
      | Pause_after of int * int
      | Timer of { timer : int; after : int; repeat : int option; limit : int; kills : int option }
      | Cancel of int
      | Signal of int
      | Step of Event_loop.step

    type channel = {
      kind : kind;
      a : Unix.file_descr;
      b : Unix.file_descr;
      watch : Event_loop.watch;
      window : Event_loop.window;
      mutable interest : Event_loop.interest;
      mutable watched : bool;
      mutable accepted : int;
      mutable received : int;
      mutable peer_closed : bool;
      mutable ended : int;
      mutable calls : int;
      mutable writable : int;
      mutable pause_after : int option;
      mutable full : bool;
    }

    type timer = {
      handle : Event_loop.timer;
      mutable active : bool;
      mutable first_due : int;
      mutable fired : int;
      mutable period : int option;
      mutable limit : int;
      mutable kills : int option;
    }

    let is_socket c = match c.kind with Socket -> true | Pipe -> false
    let reads = function Event_loop.Read | Read_write -> true | Idle | Write -> false
    let writes = function Event_loop.Write | Read_write -> true | Idle | Read -> false
    let pattern i = Char.chr (((i * 7) + 3) land 0xff)

    let check condition fmt =
      Printf.ksprintf (fun message -> if not condition then failwith message) fmt

    let max_reads = 16
    let slack = 2_000_000
    let channels_count = 3
    let timers_count = 4
    let signal_numbers = [| Sys.sigusr1; Sys.sigusr2 |]
    let hits = Array.make 2 0
    let signalled = Array.make 2 false

    external deliver_signal : int -> unit = "ko_signal_deliver"

    let () =
      Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
      Array.iteri
        (fun i signal -> Event_loop.on_signal signal (fun () -> hits.(i) <- hits.(i) + 1))
        signal_numbers

    let drop_read = function
      | Event_loop.Read | Idle -> Event_loop.Idle
      | Write | Read_write -> Write

    let make_channel kind =
      let a, b =
        match kind with
        | Socket -> Unix.socketpair ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0
        | Pipe -> Unix.pipe ~cloexec:true ()
      in
      Unix.set_nonblock a;
      Unix.set_nonblock b;
      let window = { Event_loop.buffer = Bigstringaf.create 128; off = 0; len = 64 } in
      let c =
        {
          kind;
          a;
          b;
          watch = Event_loop.watch a;
          window;
          interest = Idle;
          watched = true;
          accepted = 0;
          received = 0;
          peer_closed = false;
          ended = 0;
          calls = 0;
          writable = 0;
          pause_after = None;
          full = false;
        }
      in
      Event_loop.handle c.watch
        (Stream
           {
             window;
             on_data =
               (fun n ->
                 check c.watched "data after unwatch";
                 check (reads c.interest) "data without read interest";
                 check (n > 0 && n <= window.len) "read of %d into a window of %d" n window.len;
                 for i = 0 to n - 1 do
                   check
                     (Char.equal
                        (Bigstringaf.get window.buffer (window.off + i))
                        (pattern (c.received + i)))
                     "byte %d is wrong" (c.received + i)
                 done;
                 c.received <- c.received + n;
                 c.calls <- c.calls + 1;
                 check (c.received <= c.accepted) "more bytes delivered than written";
                 match c.pause_after with
                 | Some 1 ->
                     c.pause_after <- None;
                     c.interest <- drop_read c.interest;
                     Event_loop.interest c.watch c.interest
                 | Some k -> c.pause_after <- Some (k - 1)
                 | None -> ());
             on_end =
               (fun () ->
                 check (c.watched && c.peer_closed) "end without a closed peer";
                 check (c.received = c.accepted) "end before %d bytes arrived"
                   (c.accepted - c.received);
                 c.ended <- c.ended + 1;
                 c.watched <- false;
                 Event_loop.unwatch c.watch);
           })
        ~on_writable:(fun () ->
          check (c.watched && writes c.interest) "writable without write interest";
          check (c.peer_closed || not c.full) "writable while the send buffer is full";
          c.writable <- c.writable + 1);
      c

    let print_interest = function
      | Event_loop.Idle -> "idle"
      | Read -> "read"
      | Write -> "write"
      | Read_write -> "read+write"

    let print_op = function
      | Interest (c, i) -> Printf.sprintf "interest %d %s" c (print_interest i)
      | Window (c, o, l) -> Printf.sprintf "window %d %d %d" c o l
      | Send (c, n) -> Printf.sprintf "send %d %d" c n
      | Fill c -> Printf.sprintf "fill %d" c
      | Drain_peer c -> Printf.sprintf "drain %d" c
      | Close_peer c -> Printf.sprintf "close %d" c
      | Pause_after (c, k) -> Printf.sprintf "pause %d after %d" c k
      | Timer { timer; after; repeat; limit; kills } ->
          Printf.sprintf "timer %d after %d repeat %s limit %d kills %s" timer after
            (match repeat with Some r -> string_of_int r | None -> "-")
            limit
            (match kills with Some k -> string_of_int k | None -> "-")
      | Cancel t -> Printf.sprintf "cancel %d" t
      | Signal s -> Printf.sprintf "signal %d" s
      | Step Wait -> "wait"
      | Step Peek -> "peek"

    let op_gen =
      let open QCheck2.Gen in
      let channel = 0 -- (channels_count - 1) and index = 0 -- (timers_count - 1) in
      oneof_weighted
        [
          ( 4,
            map2
              (fun c i -> Interest (c, i))
              channel
              (oneof_list Event_loop.[ Idle; Read; Read; Write; Read_write ]) );
          (2, map3 (fun c o l -> Window (c, o, l)) channel (0 -- 32) (1 -- 96));
          (6, map2 (fun c n -> Send (c, n)) channel (oneof [ 1 -- 40; 1 -- 600; 1 -- 4000 ]));
          (1, map (fun c -> Send (c, 300_000)) channel);
          (1, map (fun c -> Fill c) channel);
          (1, map (fun c -> Drain_peer c) channel);
          (1, map (fun c -> Close_peer c) channel);
          (2, map2 (fun c k -> Pause_after (c, k)) channel (1 -- 5));
          ( 4,
            let* timer = index and* after = 0 -- 8 and* repeat = option (1 -- 4) in
            let* limit = 1 -- 4 and* kills = option index in
            return (Timer { timer; after; repeat; limit; kills }) );
          (2, map (fun t -> Cancel t) index);
          (2, map (fun s -> Signal s) (0 -- 1));
          (6, map (fun s -> Step s) (oneof_list Event_loop.[ Peek; Peek; Wait ]));
        ]

    let ceil_div a b = (a + b - 1) / b

    let run ops =
      let channels =
        Array.init channels_count (fun i -> make_channel (if i = 1 then Pipe else Socket))
      in
      let callbacks = ref [||] in
      let timers =
        Array.init timers_count (fun i ->
            {
              handle = Event_loop.timer (fun () -> !callbacks.(i) ());
              active = false;
              first_due = 0;
              fired = 0;
              period = None;
              limit = 0;
              kills = None;
            })
      in
      let last_one_shot = ref 0 and fired_total = ref 0 in
      let guard_fired = ref false in
      let guard = Event_loop.timer (fun () -> guard_fired := true) in
      let cancel i =
        let t = timers.(i) in
        t.active <- false;
        Event_loop.stop_timer t.handle
      in
      let make_callback i =
       fun () ->
        let t = timers.(i) in
        let now = Native.now () in
        check t.active "timer %d fired while cancelled" i;
        let due =
          t.first_due + (t.fired * match t.period with Some p -> p * 1_000_000 | None -> 0)
        in
        check (now >= due) "timer %d fired %d ns early" i (due - now);
        (match t.period with
        | None ->
            check (t.first_due + slack >= !last_one_shot) "one-shot timer %d fired out of order" i;
            last_one_shot := max !last_one_shot t.first_due;
            t.active <- false
        | Some _ -> ());
        t.fired <- t.fired + 1;
        incr fired_total;
        (match t.kills with Some j -> cancel j | None -> ());
        if t.fired >= t.limit && t.active then cancel i
      in
      callbacks := Array.init timers_count make_callback;
      let cleanup () =
        Event_loop.stop_timer guard;
        Array.iter (fun t -> Event_loop.stop_timer t.handle) timers;
        Array.iter
          (fun c ->
            Event_loop.close c.watch;
            if not c.peer_closed then Unix.close c.b)
          channels;
        Array.fill hits 0 2 0;
        Array.fill signalled 0 2 false
      in
      let available c = c.accepted - c.received in
      let predicted_calls c =
        if c.watched && reads c.interest && available c > 0 then begin
          let n = min max_reads (ceil_div (available c) c.window.len) in
          match c.pause_after with Some k -> min k n | None -> n
        end
        else 0
      in
      let step mode =
        let now = Native.now () in
        let expected = Array.map predicted_calls channels in
        let ends_now =
          Array.map
            (fun c -> c.watched && reads c.interest && c.peer_closed && available c = 0)
            channels
        in
        let writable_now =
          Array.mapi
            (fun i c ->
              c.watched && writes c.interest && (not (c.peer_closed || c.full)) && not ends_now.(i))
            channels
        in
        let due_now =
          Array.map
            (fun t -> t.active && Option.is_none t.period && now >= t.first_due + slack)
            timers
        in
        let pending = Array.exists (fun t -> t.active) timers in
        let io =
          Array.exists (fun e -> e > 0) expected
          || Array.exists Fun.id ends_now || Array.exists Fun.id writable_now
        in
        let signals = signalled.(0) || signalled.(1) in
        let hits_before = Array.copy hits in
        Array.iter
          (fun c ->
            c.calls <- 0;
            c.writable <- 0)
          channels;
        let before = !fired_total in
        let mode : Event_loop.step =
          match mode with
          | Event_loop.Wait when pending || io || signals -> Wait
          | Wait | Peek -> Peek
        in
        (match mode with
        | Wait ->
            guard_fired := false;
            Event_loop.start_timer guard ~after:1000 ~repeat:None
        | Peek -> ());
        Event_loop.step mode;
        Event_loop.stop_timer guard;
        check (not !guard_fired) "step Wait blocked for a second with %s"
          (if pending then "a timer pending" else "events pending");
        Array.iteri
          (fun i c ->
            check
              (c.calls = expected.(i))
              "channel %d: %d reads, expected %d" i c.calls expected.(i);
            if ends_now.(i) then check (c.ended = 1) "channel %d: no end at a closed peer" i;
            if writable_now.(i) then
              check (c.writable = 1) "channel %d: not writable though it can write" i
            else
              check
                (c.writable <= if c.peer_closed then 1 else 0)
                "channel %d: writable while it cannot write" i)
          channels;
        Array.iteri
          (fun i t -> if due_now.(i) then check (not t.active) "timer %d is due and did not fire" i)
          timers;
        Array.iteri
          (fun s raised ->
            check
              (hits.(s) = hits_before.(s) + if raised then 1 else 0)
              "signal %d: %d callbacks for %b raised" s
              (hits.(s) - hits_before.(s))
              raised;
            signalled.(s) <- false)
          signalled;
        let hung_up =
          Array.exists (fun c -> c.watched && c.peer_closed && writes c.interest) channels
        in
        if
          (match mode with Wait -> true | Peek -> false)
          && (not io) && (not signals) && not hung_up
        then check (!fired_total > before) "step Wait returned with nothing to report"
      in
      let apply = function
        | Interest (i, interest) ->
            let c = channels.(i) in
            let interest =
              match c.kind with
              | Pipe -> (
                  match interest with
                  | Write -> Event_loop.Read
                  | Read_write -> Read
                  | other -> other)
              | Socket -> interest
            in
            if c.watched then begin
              c.interest <- interest;
              Event_loop.interest c.watch interest
            end
        | Window (i, off, len) ->
            let c = channels.(i) in
            c.window.off <- off;
            c.window.len <- len
        | Send (i, n) ->
            let c = channels.(i) in
            if not c.peer_closed then begin
              let data = Bytes.init n (fun k -> pattern (c.accepted + k)) in
              match Unix.single_write c.b data 0 n with
              | w -> c.accepted <- c.accepted + w
              | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
            end
        | Fill i ->
            let c = channels.(i) in
            if is_socket c && c.watched && not c.peer_closed then begin
              let chunk = Bytes.make 65536 'f' in
              try
                while true do
                  ignore (Unix.single_write c.a chunk 0 65536 : int)
                done
              with Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> c.full <- true
            end
        | Drain_peer i ->
            let c = channels.(i) in
            if is_socket c && not c.peer_closed then begin
              let chunk = Bytes.create 65536 in
              (try
                 while Unix.read c.b chunk 0 65536 > 0 do
                   ()
                 done
               with Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ());
              c.full <- false
            end
        | Close_peer i ->
            let c = channels.(i) in
            if not c.peer_closed then begin
              c.peer_closed <- true;
              c.full <- false;
              Unix.close c.b
            end
        | Pause_after (i, k) -> channels.(i).pause_after <- Some k
        | Timer { timer; after; repeat; limit; kills } ->
            let t = timers.(timer) in
            t.active <- true;
            t.first_due <- Native.now () + (after * 1_000_000);
            t.fired <- 0;
            t.period <- repeat;
            t.limit <- limit;
            t.kills <- kills;
            Event_loop.start_timer t.handle ~after ~repeat
        | Cancel i -> cancel i
        | Signal s ->
            signalled.(s) <- true;
            deliver_signal (Native.native_signal signal_numbers.(s))
        | Step mode -> step mode
      in
      Fun.protect ~finally:cleanup (fun () ->
          List.iter apply ops;
          Array.iter
            (fun c ->
              if c.watched then begin
                c.interest <- Read;
                c.pause_after <- None;
                c.window.off <- 0;
                c.window.len <- 64;
                Event_loop.interest c.watch Read
              end)
            channels;
          Array.iteri (fun i t -> if t.active then cancel i) timers;
          step Peek;
          let rounds = ref 0 in
          while
            !rounds < 400
            && Array.exists (fun c -> c.watched && (available c > 0 || c.peer_closed)) channels
          do
            incr rounds;
            step Peek
          done;
          Array.iteri
            (fun i c ->
              check
                (not (c.watched && c.peer_closed))
                "channel %d: no end after %d rounds" i !rounds;
              if c.watched || c.ended = 1 then
                check (c.received = c.accepted) "channel %d: %d of %d bytes" i c.received c.accepted;
              check (c.ended <= 1) "channel %d: ended %d times" i c.ended)
            channels)

    let seed, seconds = Fuzz_check.budget ()

    let%test "the event loop delivers each readable byte once, fires timers and signals as modelled"
        =
      Fuzz_check.check ?seed ?seconds ~count:200 ~name:"loop"
        ~print:(fun ops -> String.concat "; " (List.map print_op ops))
        QCheck2.Gen.(list_size (1 -- 60) op_gen)
        (fun ops ->
          run ops;
          true);
      true
  end)
