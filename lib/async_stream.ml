type knobs = { batch : float; backoff_floor : float; backoff_cap : float }

let knobs getenv =
  let ms = Timestamp.ms_env getenv in
  {
    batch = ms "KIDO_STREAM_BATCH_MS" 0.25;
    backoff_floor = ms "KIDO_STREAM_BACKOFF_MS" 0.5;
    backoff_cap = ms "KIDO_STREAM_BACKOFF_CAP_MS" 10.;
  }

let batch_bytes = 4 * 1024
let pending_max = 64 * 1024
let run_budget = 256 * 1024

(* An escape's length from s.[i]: CSI up to its final byte in @-~, OSC up to BEL or ST, neither of
   which need be there, else the escape and one byte. *)
let escape_len s i =
  let n = String.length s in
  let rec until j stop =
    if j >= n then n - i else match stop j with Some k -> k - i | None -> until (j + 1) stop
  in
  if n - i < 2 then n - i
  else
    match s.[i + 1] with
    | '[' ->
        until (i + 2) (fun j ->
            if Char.(s.[j] >= '\x40' && s.[j] <= '\x7e') then Some (j + 1) else None)
    | ']' ->
        until (i + 2) (fun j ->
            if Char.equal s.[j] '\x07' then Some (j + 1)
            else if Char.equal s.[j] '\x1b' && j + 1 < n && Char.equal s.[j + 1] '\\' then
              Some (j + 2)
            else None)
    | _ -> 2

let sanitize line =
  let b = Buffer.create (String.length line) in
  let rec go i =
    if i < String.length line then
      match line.[i] with
      | '\x1b' -> go (i + escape_len line i)
      | c when Char.code c < 0x20 && not (Char.equal c '\t') -> go (i + 1)
      | c ->
          Buffer.add_char b c;
          go (i + 1)
  in
  go 0;
  String.rdrop_while (String.contains " \t\r") (Buffer.contents b)

(* Every mutable field is under [mu]. *)
type stream = {
  dir : string;
  knobs : knobs;
  meta : Subrun.meta;
  mu : Mutex.t;
  partial : Buffer.t;
  pending : string Queue.t;
  mutable bytes : int;
  mutable total : int;
  mutable sent : int;
  mutable streamed : int;
  mutable overrun : bool;
  mutable stopping : bool;
  wake_r : Unix.file_descr;
  wake_w : Unix.file_descr;
}

type t = { stream : stream; sender : Thread.t }

let push t line =
  let l = sanitize line in
  t.total <- t.total + 1;
  Queue.push l t.pending;
  t.bytes <- t.bytes + String.length l + 1

let signal t =
  try ignore (Unix.write_substring t.wake_w "x" 0 1)
  with Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()

let write { stream = t; _ } s =
  let ready =
    Mutex.protect t.mu (fun () ->
        Buffer.add_string t.partial s;
        if String.contains s '\n' then begin
          let all = Buffer.contents t.partial in
          let rec lines start =
            match String.index_from_opt all start '\n' with
            | Some i ->
                push t (String.sub all start (i - start));
                lines (i + 1)
            | None -> start
          in
          let rest = lines 0 in
          Buffer.clear t.partial;
          Buffer.add_substring t.partial all rest (String.length all - rest)
        end;
        (* After the append, so one enormous burst leaves the newest lines. *)
        while t.bytes > pending_max && not (Queue.is_empty t.pending) do
          t.bytes <- t.bytes - (String.length (Queue.pop t.pending) + 1)
        done;
        t.bytes >= batch_bytes)
  in
  if ready then signal t

let take t =
  Mutex.protect t.mu (fun () ->
      if Queue.is_empty t.pending then None
      else if t.streamed >= run_budget then
        if t.overrun then None
        else begin
          t.overrun <- true;
          Queue.clear t.pending;
          t.bytes <- 0;
          Some
            ( Printf.sprintf "... %d bytes streamed for this run; the rest is only in %s" run_budget
                (Subrun.output_path ~dir:t.dir t.meta.id),
              0,
              0 )
        end
      else
        let text = String.concat "\n" (List.of_seq (Queue.to_seq t.pending)) in
        let batch = (text, Queue.length t.pending, t.bytes) in
        Queue.clear t.pending;
        t.bytes <- 0;
        Some batch)

let credit t lines n =
  Mutex.protect t.mu (fun () ->
      t.sent <- t.sent + lines;
      t.streamed <- t.streamed + n)

let send t text =
  match State.get_live ~dir:t.dir t.meta.parent_session with
  | Some { inbox; _ } when not (String.is_empty inbox) -> (
      let env : Msg.envelope =
        {
          kind = Stream;
          id = Msg.new_id ();
          from = { session = ""; name = t.meta.name; pane = None };
          reply_to = "";
          text;
          run = Subrun.string_of_id t.meta.id;
          output = Subrun.output_path ~dir:t.dir t.meta.id;
        }
      in
      match Msg.deliver ~path:inbox (Yojson.Safe.to_string (Msg.envelope_to_yojson env)) with
      | Ok () -> true
      | Error _ -> false)
  | _ -> false

let deliver t =
  match take t with
  | None -> None
  | Some (text, lines, n) ->
      let ok = try send t text with Sys_error _ | Unix.Unix_error _ | Failure _ -> false in
      if ok then credit t lines n;
      Some ok

let drain fd =
  let buf = Bytes.create 64 in
  try
    while Unix.read fd buf 0 64 > 0 do
      ()
    done
  with Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()

let run t =
  let rec loop ~tick ~backoff ~retry_at =
    let now = Unix.gettimeofday () in
    (match Unix.select [ t.wake_r ] [] [] (Float.max 0. (tick -. now)) with
    | [], _, _ -> ()
    | _ -> drain t.wake_r
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> ());
    let now = Unix.gettimeofday () in
    let tick = if Float.(now >= tick) then now +. t.knobs.batch else tick in
    if not (Mutex.protect t.mu (fun () -> t.stopping)) then
      if Float.(now < retry_at) then loop ~tick ~backoff ~retry_at
      else
        match deliver t with
        | None -> loop ~tick ~backoff ~retry_at
        | Some true -> loop ~tick ~backoff:0. ~retry_at:0.
        | Some false ->
            let backoff =
              if Float.(backoff = 0.) then t.knobs.backoff_floor
              else Float.min t.knobs.backoff_cap (2. *. backoff)
            in
            loop ~tick ~backoff ~retry_at:(Unix.gettimeofday () +. backoff)
  in
  loop ~tick:(Unix.gettimeofday () +. t.knobs.batch) ~backoff:0. ~retry_at:0.

let start ~dir knobs meta =
  let wake_r, wake_w = Unix.pipe ~cloexec:true () in
  Unix.set_nonblock wake_r;
  Unix.set_nonblock wake_w;
  let t =
    {
      dir;
      knobs;
      meta;
      mu = Mutex.create ();
      partial = Buffer.create 256;
      pending = Queue.create ();
      bytes = 0;
      total = 0;
      sent = 0;
      streamed = 0;
      overrun = false;
      stopping = false;
      wake_r;
      wake_w;
    }
  in
  { stream = t; sender = Thread.create run t }

let close { stream = t; sender } =
  Mutex.protect t.mu (fun () -> t.stopping <- true);
  signal t;
  Thread.join sender;
  Unix.close t.wake_r;
  Unix.close t.wake_w;
  Mutex.protect t.mu (fun () ->
      if Buffer.length t.partial > 0 then begin
        push t (Buffer.contents t.partial);
        Buffer.clear t.partial
      end);
  ignore (deliver t);
  Mutex.protect t.mu (fun () -> t.total - t.sent)

let%test_module "Tests" =
  (module struct
    open Test_fixture

    let stream_knobs batch : knobs = { batch; backoff_floor = 0.02; backoff_cap = 0.1 }

    (* A run whose parent, root-sess, listens on [inbox]. *)
    let run ?(parent = "root-sess") inbox =
      let dir = Filename.temp_dir "kido-state" "" in
      ignore (State.record ~dir "root-sess" (session ~pane:"%2" ~inbox ()));
      let meta : Subrun.meta =
        {
          id = Subrun.new_id ();
          name = "chatty";
          kind = Bash;
          parent_session = parent;
          depth = 1;
          pane = Tmux.pane_id_of_string "";
          pid = 0;
          cwd = "";
          model = "";
          tools = [];
          keep_alive = false;
          started_at = 0.;
        }
      in
      (dir, meta)

    let chunks received =
      List.filter_map
        (fun raw ->
          match Test_fixture.envelope raw with
          | Some e when String.equal (e "kind") "stream" ->
              assert (String.equal (e "from.name") "chatty");
              Some (e "text")
          | _ -> None)
        (received ())

    let%expect_test "what travels loses escape sequences, control bytes and trailing blanks" =
      List.iter
        (fun l -> Printf.printf "%S -> %S\n" l (sanitize l))
        [
          "\027[32mline 1\027[0m";
          "a\tb\r";
          "bell\007 and \001soh";
          "\027]0;title\007after";
          "\027]8;;http://x\027\\link";
          "\027[unterminated";
          "\027]unterminated";
          "\027(Bcharset";
          "trailing \027";
          "spaces   \t ";
        ];
      let k =
        knobs (function
          | "KIDO_STREAM_BATCH_MS" -> Some "40"
          | "KIDO_STREAM_BACKOFF_MS" -> Some "0"
          | _ -> None)
      in
      Printf.printf "batch=%g floor=%g cap=%g\n" k.batch k.backoff_floor k.backoff_cap;
      [%expect
        {|
    "\027[32mline 1\027[0m" -> "line 1"
    "a\tb\r" -> "a\tb"
    "bell\007 and \001soh" -> "bell and soh"
    "\027]0;title\007after" -> "after"
    "\027]8;;http://x\027\\link" -> "link"
    "\027[unterminated" -> "nterminated"
    "\027]unterminated" -> ""
    "\027(Bcharset" -> "Bcharset"
    "trailing \027" -> "trailing"
    "spaces   \t " -> "spaces"
    batch=0.04 floor=0.5 cap=10
    |}]

    (* Lines are written slowly, so a sender with one envelope per line is not masked by coalescing,
   and the count is judged against the batch windows the writing spanned. *)
    let%expect_test "lines written one at a time arrive as a few chunks" =
      let inbox, received = start_inbox ~reply:"ok\n" in
      let dir, meta = run inbox in
      let s = start ~dir (stream_knobs 2.) meta in
      let t0 = Unix.gettimeofday () in
      for i = 1 to 20 do
        write s (Printf.sprintf "\027[32mline %d\027[0m\n" i);
        Thread.delay 0.03
      done;
      let unstreamed = close s in
      let elapsed = Unix.gettimeofday () -. t0 in
      let got = chunks received in
      Printf.printf "few chunks: %b\n" (List.length got <= int_of_float (elapsed /. 2.) + 2);
      Printf.printf "unstreamed %d\n%s\n" unstreamed (String.concat "\n" got);
      [%expect
        {|
    few chunks: true
    unstreamed 0
    line 1
    line 2
    line 3
    line 4
    line 5
    line 6
    line 7
    line 8
    line 9
    line 10
    line 11
    line 12
    line 13
    line 14
    line 15
    line 16
    line 17
    line 18
    line 19
    line 20
    |}]

    (* The wire has no sequencing, so a notice sent after close must follow every chunk. *)
    let%expect_test "close flushes the last line, even unterminated, before it returns" =
      let inbox, received = start_inbox ~reply:"ok\n" in
      let dir, meta = run inbox in
      let s = start ~dir (stream_knobs 5.) meta in
      write s "line 1\nline 2\nli";
      write s "ne 3\nline 4 unterminated";
      Printf.printf "unstreamed %d\n" (close s);
      List.iter print_endline (chunks received);
      [%expect {|
    unstreamed 0
    line 1
    line 2
    line 3
    line 4 unterminated
    |}]

    (* The output file is the source of truth: a parent that is gone, or listening and never
   answering, must cost the writer nothing, and nothing it did not acknowledge counts as sent. *)
    let%expect_test "a parent that cannot be reached never blocks a write" =
      let slowest = ref 0. in
      let feed s =
        for i = 1 to 60 do
          let t0 = Unix.gettimeofday () in
          write s (Printf.sprintf "line %d\n" i);
          slowest := Float.max !slowest (Unix.gettimeofday () -. t0);
          Thread.delay 0.01
        done;
        close s
      in
      let stalled, received = start_inbox ~reply:"" in
      List.iter
        (fun (what, (dir, meta)) ->
          slowest := 0.;
          let unstreamed = feed (start ~dir (stream_knobs 0.02) meta) in
          Printf.printf "%s: unstreamed %d, writes under 50ms: %b\n" what unstreamed
            Float.(!slowest < 0.05))
        [
          ("no parent", run ~parent:"" "");
          ("parent without an inbox", run "");
          ("nothing listening", run "/nonexistent/inbox.sock");
          ("never answering", run stalled);
        ];
      Printf.printf "the stalled inbox was sent to: %b\n" (not (List.is_empty (received ())));
      [%expect
        {|
    no parent: unstreamed 60, writes under 50ms: true
    parent without an inbox: unstreamed 60, writes under 50ms: true
    nothing listening: unstreamed 60, writes under 50ms: true
    never answering: unstreamed 60, writes under 50ms: true
    the stalled inbox was sent to: true
    |}]

    let%expect_test "past the run's budget one line says so, and nothing follows it" =
      let inbox, received = start_inbox ~reply:"ok\n" in
      let dir, meta = run inbox in
      let s = start ~dir (stream_knobs 0.01) meta in
      let line = String.make 999 'x' ^ "\n" in
      for _ = 1 to 100 do
        write s (String.concat "" [ line; line; line; line ]);
        Thread.delay 0.005
      done;
      let unstreamed = close s in
      let got = chunks received in
      let is_budget = String.prefix ~pre:"... 262144 bytes streamed for this run" in
      Printf.printf "budget lines %d, last %b, unstreamed > 0 %b\n"
        (List.length (List.filter is_budget got))
        (is_budget (List.hd (List.rev got)))
        (unstreamed > 0);
      print_endline
        (String.replace ~sub:dir ~by:"<dir>" (List.find is_budget got)
        |> String.replace ~sub:(Subrun.string_of_id meta.id) ~by:"<run>");
      [%expect
        {|
    budget lines 1, last true, unstreamed > 0 true
    ... 262144 bytes streamed for this run; the rest is only in <dir>/runs/<run>/output
    |}]
  end)
