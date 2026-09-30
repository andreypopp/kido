open Kido
open Fixture

let knobs batch : Async_stream.knobs = { batch; backoff_floor = 0.02; backoff_cap = 0.1 }

(* A run whose parent, root-sess, listens on [inbox]. *)
let run ?(parent = "root-sess") inbox =
  let dir = Filename.temp_dir "kido-state" "" in
  ignore (State.record ~dir "root-sess" (session ~pane:"%2" ~inbox Idle));
  let meta : Subrun.meta =
    {
      id = Subrun.new_id ();
      name = "chatty";
      kind = Some Bash;
      parent_session = parent;
      depth = 1;
      pane = "";
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
      match Msg.parse raw with
      | Some { kind = Stream; text; from; _ } ->
          assert (String.equal from.name "chatty");
          Some text
      | _ -> None)
    (received ())

let%expect_test "what travels loses escape sequences, control bytes and trailing blanks" =
  List.iter
    (fun l -> Printf.printf "%S -> %S\n" l (Async_stream.sanitize l))
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
    Async_stream.knobs (function
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
  let s = Async_stream.start ~dir (knobs 2.) meta in
  let t0 = Unix.gettimeofday () in
  for i = 1 to 20 do
    Async_stream.write s (Printf.sprintf "\027[32mline %d\027[0m\n" i);
    Thread.delay 0.03
  done;
  let unstreamed = Async_stream.close s in
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
  let s = Async_stream.start ~dir (knobs 5.) meta in
  Async_stream.write s "line 1\nline 2\nli";
  Async_stream.write s "ne 3\nline 4 unterminated";
  Printf.printf "unstreamed %d\n" (Async_stream.close s);
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
      Async_stream.write s (Printf.sprintf "line %d\n" i);
      slowest := Float.max !slowest (Unix.gettimeofday () -. t0);
      Thread.delay 0.01
    done;
    Async_stream.close s
  in
  let stalled, received = start_inbox ~reply:"" in
  List.iter
    (fun (what, (dir, meta)) ->
      slowest := 0.;
      let unstreamed = feed (Async_stream.start ~dir (knobs 0.02) meta) in
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
  let s = Async_stream.start ~dir (knobs 0.01) meta in
  let line = String.make 999 'x' ^ "\n" in
  for _ = 1 to 100 do
    Async_stream.write s (String.concat "" [ line; line; line; line ]);
    Thread.delay 0.005
  done;
  let unstreamed = Async_stream.close s in
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
