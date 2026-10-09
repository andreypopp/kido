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
  let s = session () ~ts:1_700_000_000.25 in
  print_endline (Yojson.Safe.to_string (State.session_to_yojson { s with pid = 42 }));
  [%expect {| {"agent":"pi","name":"","pane":"%1","pid":42,"ts":"2023-11-14T22:13:20.25Z"} |}]

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

let%expect_test "the latest report wins a shared pane" =
  let dir = temp () in
  write ~dir "a" (session ~pane:"%1" ~ts:100. ());
  write ~dir "b" (session ~pane:"%1" ~ts:200. ());
  write ~dir "pi-root" (session ~agent:Pi ~pane:"%9" ~ts:100. ());
  write ~dir "pi-headless" (session ~agent:(Other "pi2") ~pane:"%9" ~ts:200. ());
  show_panes (State.load_live ~dir);
  Fs.remove (Filename.concat dir "pi-headless.json");
  show_panes (State.load_live ~dir);
  [%expect {|
    %1: b
    %9: pi-headless
    %1: b
    %9: pi-root
    |}]

let%expect_test "load_live deletes a dead agent's record and skips a malformed one" =
  let dir = temp () in
  write ~dir "live" (session () ~pane:"%1");
  write ~dir "dead" (session () ~pane:"%2" ~pid:(dead_pid ()));
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
  write ~dir "live" (session () ~pane:"%1");
  write ~dir "dead" (session () ~pane:"%2" ~pid:(dead_pid ()));
  Fs.write
    (Filename.concat dir "no-pane.json")
    (Yojson.Safe.to_string
       (`Assoc
          (("pane", `String "")
          :: List.remove_assoc ~eq:String.equal "pane"
               (Yojson.Safe.Util.to_assoc (State.session_to_yojson (session ()))))));
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
  outcome (State.record ~dir "s" { (session () ~pane:"%1" ~pid:1) with inbox = "/tmp/h.sock" });
  outcome (State.record ~dir "s" (session () ~pane:"%2" ~pid:me));
  outcome (State.remove ~dir "s" ~pid:me);
  Option.iter
    (fun (s : State.session) ->
      Printf.printf "kept %s %d %s\n"
        (Option.map_or ~default:"" Tmux.Pane.to_string s.pane)
        s.pid s.inbox)
    (State.get ~dir "s");
  outcome (State.record ~dir "d" (session () ~pane:"%1" ~pid:(dead_pid ())));
  outcome (State.record ~dir "d" (session () ~pane:"%2" ~pid:me));
  Option.iter
    (fun (s : State.session) ->
      Printf.printf "taken over by %s\n" (Option.map_or ~default:"" Tmux.Pane.to_string s.pane))
    (State.get ~dir "d");
  outcome (State.record ~dir "d" (session () ~pane:"%2" ~pid:me));
  outcome (State.remove ~dir "d" ~pid:me);
  Printf.printf "removed %b\n" (Option.is_none (State.get ~dir "d"));
  print_endline (State.held_message "s" (session () ~pane:"%1" ~pid:1));
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

let%expect_test "only a root app identifies a pane" =
  let p = pane ~cmd:"pi" "%1" in
  let states = State.by_pane [ ("local", session ()) ] in
  List.iter
    (fun (body, local) ->
      let status = Result.get_exn (Tmux.Program_status.parse body) in
      let programs = Tmux.Pane.Map.singleton p.pane_id status in
      let states = if local then states else Tmux.Pane.Map.empty in
      let kind = State.pane_kind ~programs ~states p in
      print_endline
        (match kind with
        | Terminal -> "terminal"
        | Some_agent { name } -> "native " ^ name
        | Pi_agent { id; _ } -> "local " ^ id))
    [
      ({|{"serial":1,"records":[]}|}, true);
      ({|{"serial":1,"records":[{"id":"child","app":"pi","state":"idle"}]}|}, true);
      ({|{"serial":1,"records":[{"id":"","app":"pi","state":"idle"}]}|}, true);
      ({|{"serial":1,"records":[{"id":"","app":"pi","state":"idle"}]}|}, false);
      ({|{"serial":1,"records":[{"id":"","app":"claude-code","state":"idle"}]}|}, true);
      ({|{"serial":1,"records":[{"id":"","app":"builder","state":"idle"}]}|}, true);
    ];
  [%expect
    {|
    terminal
    terminal
    local local
    native pi
    native claude-code
    terminal
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
