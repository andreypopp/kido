open Kido

let dead_pid () =
  let pid = Unix.create_process "true" [| "true" |] Unix.stdin Unix.stdout Unix.stderr in
  ignore (Unix.waitpid [] pid);
  pid

let session ?(agent = State.Pi) ?(pane = "%1") ?(pid = Unix.getpid ()) ?(ts = 1_700_000_000.)
    ?(background = false) ?(tool_pending = false) status : State.session =
  {
    agent;
    pane;
    pid;
    status;
    ts;
    title = "";
    inbox = "";
    ended = None;
    background;
    tool_pending;
    activity = "";
    parent = None;
    depth = 0;
    model = "";
  }

let write ~dir id s =
  Fs.write (Filename.concat dir (id ^ ".json")) (Yojson.Safe.to_string (State.session_to_yojson s))

let temp () = Filename.temp_dir "kido-state" ""

let show_panes live =
  State.Panes.iter (fun pane (id, _) -> Printf.printf "%s: %s\n" pane id) (State.by_pane live)

let outcome = function
  | Ok () -> print_endline "ok"
  | Error (h : State.session) -> Printf.printf "held by pid %d in %s\n" h.pid h.pane

let%expect_test "a record is written compactly, without its empty fields" =
  let s = { (session Running ~ts:1_700_000_000.25) with ended = Some 1_700_000_000. } in
  print_endline (Yojson.Safe.to_string (State.session_to_yojson { s with pid = 42 }));
  [%expect
    {| {"agent":"pi","pane":"%1","pid":42,"status":"running","ts":"2023-11-14T22:13:20.25Z","ended":"2023-11-14T22:13:20Z"} |}]

let%expect_test "timestamps round-trip through RFC 3339" =
  List.iter
    (fun t ->
      let s = Timestamp.to_string t in
      Printf.printf "%s %b\n" s
        (Option.exists (fun t' -> Float.(abs (t' - t) < 1e-6)) (Timestamp.of_string s)))
    [ 0.; 1_700_000_000.; 1_700_000_000.5; 951_782_400.123456 ];
  print_endline (Option.map_or ~default:"none" Timestamp.to_string (Timestamp.of_string "junk"));
  [%expect
    {|
    1970-01-01T00:00:00Z true
    2023-11-14T22:13:20Z true
    2023-11-14T22:13:20.5Z true
    2000-02-29T00:00:00.123456Z true
    none
    |}]

let%expect_test "stalled only while running without a background wait or a tool call" =
  let now = 1_700_000_000. in
  List.iter
    (fun (name, s, wake) ->
      Printf.printf "%-28s %b\n" name (State.stalled_since ~threshold:60. ~wake ~now s))
    [
      ("just under the threshold", session Running ~ts:(now -. 59.), None);
      ("exactly at the threshold", session Running ~ts:(now -. 60.), None);
      ("idle, however stale", session Idle ~ts:(now -. 3600.), None);
      ("waiting, however stale", session Waiting ~ts:(now -. 3600.), None);
      ("parked on background work", session Running ~ts:(now -. 86400.) ~background:true, None);
      ("inside a tool call", session Running ~ts:(now -. 10800.) ~tool_pending:true, None);
      ("a wake inside the threshold", session Running ~ts:(now -. 3600.), Some (now -. 59.));
      ("a wake past the threshold", session Running ~ts:(now -. 3600.), Some (now -. 60.));
      ("a report after the wake", session Running ~ts:(now -. 1.), Some (now -. 120.));
    ];
  [%expect
    {|
    just under the threshold     false
    exactly at the threshold     true
    idle, however stale          false
    waiting, however stale       false
    parked on background work    false
    inside a tool call           false
    a wake inside the threshold  false
    a wake past the threshold    true
    a report after the wake      false
    |}]

let%expect_test "the outer agent wins a shared pane; otherwise the latest report does" =
  let dir = temp () in
  write ~dir "pi-1" (session ~agent:Pi ~pane:"%3" ~ts:100. Running);
  write ~dir "claude-1" (session ~agent:Claude ~pane:"%3" ~ts:200. Idle);
  write ~dir "a" (session ~agent:Claude ~pane:"%1" ~ts:100. Idle);
  write ~dir "b" (session ~agent:Claude ~pane:"%1" ~ts:200. Running);
  write ~dir "pi-root" (session ~agent:Pi ~pane:"%9" ~ts:100. Idle);
  write ~dir "pi-headless" (session ~agent:(Other "pi2") ~pane:"%9" ~ts:200. Running);
  show_panes (State.load_live ~dir);
  Fs.remove (Filename.concat dir "pi-headless.json");
  show_panes (State.load_live ~dir);
  [%expect
    {|
    %1: b
    %3: pi-1
    %9: pi-headless
    %1: b
    %3: pi-1
    %9: pi-root
    |}]

let%expect_test "load_live deletes a dead agent's record and skips a malformed one" =
  let dir = temp () in
  write ~dir "live" (session Idle ~pane:"%1");
  write ~dir "dead" (session Idle ~pane:"%2" ~pid:(dead_pid ()));
  Fs.write (Filename.concat dir "malformed.json") "{not json";
  Unix.mkdir (Filename.concat dir "runs.json") 0o755;
  List.iter (fun (id, _) -> print_endline id) (State.load_live ~dir);
  List.iter
    (fun f -> Printf.printf "%s %b\n" f (Sys.file_exists (Filename.concat dir f)))
    [ "dead.json"; "malformed.json" ];
  [%expect {|
    live
    dead.json false
    malformed.json true
    |}]

let%expect_test "one live holder per session id" =
  let dir = temp () in
  let me = Unix.getpid () in
  outcome (State.record ~dir "s" { (session Running ~pane:"%1" ~pid:1) with inbox = "/tmp/h.sock" });
  outcome (State.record ~dir "s" (session Idle ~pane:"%2" ~pid:me));
  outcome (State.remove ~dir "s" ~pid:me);
  Option.iter
    (fun (s : State.session) -> Printf.printf "kept %s %d %s\n" s.pane s.pid s.inbox)
    (State.get ~dir "s");
  outcome (State.record ~dir "d" (session Idle ~pane:"%1" ~pid:(dead_pid ())));
  outcome (State.record ~dir "d" (session Running ~pane:"%2" ~pid:me));
  Option.iter
    (fun (s : State.session) -> Printf.printf "taken over by %s\n" s.pane)
    (State.get ~dir "d");
  outcome (State.record ~dir "d" (session Idle ~pane:"%2" ~pid:me));
  outcome (State.remove ~dir "d" ~pid:me);
  Printf.printf "removed %b\n" (Option.is_none (State.get ~dir "d"));
  print_endline (State.held_message "s" (session Running ~pane:"%1" ~pid:1));
  [%expect
    {|
    ok
    held by pid 1 in %1
    held by pid 1 in %1
    kept %1 1 /tmp/h.sock
    ok
    ok
    taken over by %2
    ok
    ok
    removed true
    session s is already open in pane %1 (pid 1); this process is not tracked
    |}]

let%expect_test "the wake marker keeps the latest wake" =
  let dir = temp () in
  let show () =
    print_endline (Option.map_or ~default:"none" Timestamp.to_string (State.wake ~dir))
  in
  show ();
  State.record_pause ~dir 1_700_001_000.;
  State.record_pause ~dir 1_700_000_000.;
  show ();
  [%expect {|
    none
    2023-11-14T22:30:00Z
    |}]

let%expect_test "a pause is the wall clock outrunning the monotonic one" =
  let reading wall mono_s : State.reading =
    { wall; mono = Mtime.of_uint64_ns (Int64.of_float (mono_s *. 1e9)) }
  in
  List.iter
    (fun (name, wall, mono) ->
      Printf.printf "%-26s %b\n" name
        (State.detect_pause (reading 1000. 1000.) (reading (1000. +. wall) (1000. +. mono))))
    [
      ("awake, tick on schedule", 0.1, 0.1);
      ("awake, tick genuinely slow", 300., 300.);
      ("just under the slack", 4.999, 0.);
      ("just over the slack", 5.001, 0.);
      ("asleep for minutes", 300., 0.05);
    ];
  [%expect
    {|
    awake, tick on schedule    false
    awake, tick genuinely slow false
    just under the slack       false
    just over the slack        true
    asleep for minutes         true
    |}]

let%expect_test "agent_title" =
  List.iter
    (fun t -> Printf.printf "[%s]\n" (State.agent_title t))
    [
      "✳ Tmux config";
      "⠂ Fix it";
      "π - kido - internal";
      "π - cwd";
      "·  2 tasks";
      "Plain";
      "✳️ Ёлка";
      "";
    ];
  [%expect
    {|
    [Tmux config]
    [Fix it]
    [kido - internal]
    [cwd]
    [2 tasks]
    [Plain]
    [Ёлка]
    []
    |}]
