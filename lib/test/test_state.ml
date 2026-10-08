open Kido
open Fixture

let write ~dir id s =
  Fs.write (Filename.concat dir (id ^ ".json")) (Yojson.Safe.to_string (State.session_to_yojson s))

let temp () = Filename.temp_dir "kido-state" ""

let show_panes live =
  Tmux.Pane.Map.iter
    (fun pane (id, _) -> Printf.printf "%s: %s\n" (Tmux.Pane.to_string pane) id)
    (State.by_pane live)

let outcome = function
  | Ok () -> print_endline "ok"
  | Error (h : State.session) ->
      Printf.printf "held by pid %d in %s\n" h.pid
        (Option.map_or ~default:"" Tmux.Pane.to_string h.pane)

let%expect_test "a record is written compactly, without its empty fields" =
  let s = session Idle ~ts:1_700_000_000.25 in
  print_endline (Yojson.Safe.to_string (State.session_to_yojson { s with pid = 42 }));
  [%expect
    {| {"agent":"pi","pane":"%1","pid":42,"reporting":["Terminal"],"ts":"2023-11-14T22:13:20.25Z"} |}]

let%expect_test "timestamps round-trip through RFC 3339" =
  List.iter
    (fun t ->
      let s = Timestamp.to_string t in
      Printf.printf "%s %b\n" s
        (Option.exists (fun t' -> Float.(abs (t' - t) < 1e-6)) (Timestamp.of_string s)))
    [ 0.; 1_700_000_000.; 1_700_000_000.5; 951_782_400.123456 ];
  print_endline (Option.map_or ~default:"none" Timestamp.to_string (Timestamp.of_string "junk"));
  List.iter
    (fun s ->
      print_endline (Option.map_or ~default:"none" Timestamp.to_string (Timestamp.of_string s)))
    [ "2026-09-29T16:36:24.275927+02:00"; "2026-09-29T11:06:24-03:30"; "2026-09-29T14:36:24+2" ];
  [%expect
    {|
    1970-01-01T00:00:00Z true
    2023-11-14T22:13:20Z true
    2023-11-14T22:13:20.5Z true
    2000-02-29T00:00:00.123456Z true
    none
    2026-09-29T14:36:24.275927Z
    2026-09-29T14:36:24Z
    none
    |}]

let%expect_test "Hook stalls only while running without a background wait or a tool call" =
  let session = session ~agent:State.Claude in
  let now = 1_700_000_000. in
  List.iter
    (fun (name, s, wake) ->
      Printf.printf "%-28s %b\n" name
        (State.stalled_since ~programs:Tmux.Pane.Map.empty ~threshold:60. ~wake ~now s))
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

let%expect_test "get_live reads one session without deleting dead records" =
  let dir = temp () in
  write ~dir "live" (session Idle ~pane:"%1");
  write ~dir "dead" (session Idle ~pane:"%2" ~pid:(dead_pid ()));
  Fs.write
    (Filename.concat dir "no-pane.json")
    (Yojson.Safe.to_string
       (`Assoc
          (("pane", `String "")
          :: List.remove_assoc ~eq:String.equal "pane"
               (Yojson.Safe.Util.to_assoc (State.session_to_yojson (session Idle))))));
  List.iter
    (fun id -> Printf.printf "%s %b\n" id (Option.is_some (State.get_live ~dir id)))
    [ "live"; "dead"; "no-pane"; "missing" ];
  Printf.printf "dead record kept %b\n" (Option.is_some (State.get ~dir "dead"));
  [%expect
    {|
    live true
    dead false
    no-pane true
    missing false
    dead record kept true
    |}]

let%expect_test "one live holder per session id" =
  let dir = temp () in
  let me = Unix.getpid () in
  outcome (State.record ~dir "s" { (session Running ~pane:"%1" ~pid:1) with inbox = "/tmp/h.sock" });
  outcome (State.record ~dir "s" (session Idle ~pane:"%2" ~pid:me));
  outcome (State.remove ~dir "s" ~pid:me);
  Option.iter
    (fun (s : State.session) ->
      Printf.printf "kept %s %d %s\n"
        (Option.map_or ~default:"" Tmux.Pane.to_string s.pane)
        s.pid s.inbox)
    (State.get ~dir "s");
  outcome (State.record ~dir "d" (session Idle ~pane:"%1" ~pid:(dead_pid ())));
  outcome (State.record ~dir "d" (session Running ~pane:"%2" ~pid:me));
  Option.iter
    (fun (s : State.session) ->
      Printf.printf "taken over by %s\n" (Option.map_or ~default:"" Tmux.Pane.to_string s.pane))
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

let%expect_test "is_agent_pane: reported, running claude, a pi in the tree, a plain shell" =
  let states = State.by_pane [ ("pi-1", session ~pane:"%2" Running) ] in
  let pane id pid cmd : Tmux.Pane.t =
    {
      session_name = "";
      session_id = Option.get_exn_or "id" (Tmux.Session.of_string "$0");
      session_created = 0.;
      window_index = 0;
      window_id = Option.get_exn_or "id" (Tmux.Window.of_string "@0");
      window_name = "";
      window_layout = "";
      pane_id = Option.get_exn_or "id" (Tmux.Pane.of_string id);
      active = false;
      pane_active = false;
      pane_pid = pid;
      current_command = cmd;
      current_path = "";
      alternate_on = false;
      command_running = false;
      command_start = None;
      last_prompt = None;
      last_exit = None;
      command_line = "";
      dead_at = None;
      run = None;
      session_attached = false;
      title = "";
    }
  in
  let pi = Procs.Int_set.of_list [ 12 ] in
  List.iter
    (fun (name, pi, p) -> Printf.printf "%s: %b\n" name (State.is_agent_pane states ~pi p))
    [
      ("reported", Procs.Int_set.empty, pane "%2" 10 "node");
      ("claude command", Procs.Int_set.empty, pane "%9" 11 "claude");
      ("pi in the tree", pi, pane "%9" 12 "node");
      ("plain shell", pi, pane "%9" 13 "bash");
    ];
  [%expect
    {|
    reported: true
    claude command: true
    pi in the tree: true
    plain shell: false
    |}]

let%expect_test "a missing state dir holds no records; an unreadable one is an error" =
  let dir = Filename.concat (Filename.temp_dir "kido-state" "") "absent" in
  Printf.printf "missing: %d\n" (List.length (State.load_live ~dir));
  Unix.mkdir dir 0o000;
  (match State.load_live ~dir with
  | l -> Printf.printf "unreadable: %d records\n" (List.length l)
  | exception Sys_error _ -> print_endline "unreadable: error");
  Unix.chmod dir 0o755;
  [%expect {|
    missing: 0
    unreadable: error
    |}]
