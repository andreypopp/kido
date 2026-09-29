open Kido
open Fixture

let attempt f =
  match f () with
  | code -> Printf.printf "-> %d\n" code
  | exception Failure m -> Printf.printf "refused: %s\n" m

let runs dir = Filename.concat dir "runs"
let id s = Result.get_exn (Subrun.parse_id s)

let outcome ~dir run result =
  ignore
    (Subrun.record_outcome ~dir:(runs dir) (id run) { result; text = ""; at = Some 1_700_000_090. })

let show_outcome ~dir run =
  match Subrun.read_outcome ~dir:(runs dir) (id run) with
  | None -> print_endline "no outcome"
  | Some o -> Printf.printf "outcome %s %S\n" (Reap.string_of_result o.result) o.text

let%expect_test "runs: the table newest first, one run shown, and --json" =
  let dir = Filename.temp_dir "kido-state" "" in
  ignore
    (run ~dir ~name:"kid" ~kind:Agent ~parent:"root" ~cwd:"/tmp/some project"
       ~started_at:1_700_000_000. "run-a");
  outcome ~dir "run-a" Completed;
  ignore (run ~dir ~name:"later" ~kind:Bash ~pid:(dead_pid ()) ~started_at:1_700_003_600. "run-b");
  ignore (Runs.runs ~dir ~json:false []);
  ignore (Runs.runs ~dir ~json:false [ "run-a" ]);
  [%expect
    {|
    ID     NAME   PARENT  STARTED               DURATION  OUTCOME    CWD
    run-b  later          2023-11-14T23:13:20Z  -         died
    run-a  kid    root    2023-11-14T22:13:20Z  1m30s     completed  /tmp/some project
    id:       run-a
    name:     kid
    kind:     agent
    parent:   root
    depth:    1
    cwd:      /tmp/some project
    started:  2023-11-14T22:13:20Z
    outcome:  completed
    ended:    2023-11-14T22:14:50Z
    resume:   cd '/tmp/some project' && kido spawn_subagent --resume run-a
    fork:     cd '/tmp/some project' && pi --fork run-a
    task:
    do the thing
    |}];
  ignore (Runs.runs ~dir ~json:true [ "run-a" ]);
  let shown = Yojson.Safe.from_string [%expect.output] in
  ignore (Runs.runs ~dir ~json:true []);
  let listed = Yojson.Safe.from_string [%expect.output] in
  Yojson.Safe.Util.(
    print_endline (String.concat " " (keys shown));
    List.iter
      (fun r ->
        Printf.printf "%s %s\n"
          (to_string (member "id" r))
          (match member "outcome" r with `Null -> "running" | o -> to_string (member "result" o)))
      (to_list listed));
  attempt (fun () -> Runs.runs ~dir ~json:false [ "run-a"; "extra" ]);
  attempt (fun () -> Runs.runs ~dir ~json:false [ "no-such-run" ]);
  [%expect
    {|
    id name kind parentSession depth pane pid cwd startedAt outcome task resume fork
    run-b died
    run-a completed
    refused: unknown argument "extra"
    usage: kido runs [--json] [<run-id>]
    refused: run "no-such-run": no such run
    |}]

let%expect_test "runs: running while the run's process lives, died once it is gone" =
  let dir = Filename.temp_dir "kido-state" "" in
  ignore (run ~dir ~pid:(Unix.getpid ()) "run-live");
  ignore (run ~dir ~pid:(dead_pid ()) "run-dead");
  List.concat_map
    (fun r ->
      ignore (Runs.runs ~dir ~json:false [ r ]);
      String.lines [%expect.output] |> List.filter (String.prefix ~pre:"outcome:"))
    [ "run-live"; "run-dead" ]
  |> List.iter print_endline;
  [%expect {|
    outcome:  running
    outcome:  died
    |}]

let no_capture pane =
  Printf.printf "captured %s, want no capture at all\n" pane;
  None

let run_outcome ~dir ?(capture = no_capture) ?(text = "") ?(unreported = false) result r =
  attempt (fun () -> Runs.run_outcome ~dir ~capture ~result ~text ~unreported r)

(* A run's own process must not claim an outcome only kido assigns from the outside. *)
let%expect_test "run-outcome records completed or failed, and nothing else" =
  let dir = Filename.temp_dir "kido-state" "" in
  ignore (run ~dir ~pane:"%9" "run-x");
  List.iter (fun r -> run_outcome ~dir r "run-x") [ "died"; "stopped"; "bogus"; "" ];
  show_outcome ~dir "run-x";
  run_outcome ~dir "completed" "run-x";
  show_outcome ~dir "run-x";
  run_outcome ~dir ~capture:(fun _ -> None) "failed" "run-x";
  run_outcome ~dir "completed" "../escape";
  [%expect
    {|
    refused: --result must be "completed" or "failed"
    usage: kido run-outcome --result completed|failed [--text TEXT] [--unreported] <run-id>
    refused: --result must be "completed" or "failed"
    usage: kido run-outcome --result completed|failed [--text TEXT] [--unreported] <run-id>
    refused: --result must be "completed" or "failed"
    usage: kido run-outcome --result completed|failed [--text TEXT] [--unreported] <run-id>
    refused: --result must be "completed" or "failed"
    usage: kido run-outcome --result completed|failed [--text TEXT] [--unreported] <run-id>
    no outcome
    -> 0
    outcome completed ""
    refused: run run-x already has an outcome, or is gone
    refused: invalid run id "../escape"
    |}]

(* run-outcome runs inside the child, whose pane is alive only until it exits: a failure saves it
   before returning. A completed ending never captures (no_capture would say so). *)
let%expect_test "run-outcome: a failure keeps the child's own screen, refined by pi's login line" =
  let dir = Filename.temp_dir "kido-state" "" in
  let no_turn =
    "no turn ever ran: the task was delivered and the session never started work on it"
  in
  List.iter
    (fun (r, screen, text) ->
      ignore (run ~dir ~pane:"%9" r);
      let capture pane =
        Printf.printf "captured %s\n" pane;
        Some screen
      in
      run_outcome ~dir ~capture ~text "failed" r;
      show_outcome ~dir r;
      Printf.printf "screen: %S\n"
        (Option.get_or ~default:"none" (Subrun.read_screen ~dir:(runs dir) (id r))))
    [
      ("run-screen", "pi's last screen before it exited\n", no_turn);
      ("run-login", "Use /login to log into a provider via OAuth or API key\n", no_turn);
      ("run-other", "Use /login to log into a provider via OAuth or API key\n", "exit 1");
    ];
  ignore (run ~dir ~pane:"%9" "run-ok");
  run_outcome ~dir "completed" "run-ok";
  Printf.printf "screen for completed: %b\n"
    (Option.is_some (Subrun.read_screen ~dir:(runs dir) (id "run-ok")));
  [%expect
    {|
    captured %9
    -> 0
    outcome failed "no turn ever ran: the task was delivered and the session never started work on it"
    screen: "pi's last screen before it exited\n"
    captured %9
    -> 0
    outcome failed "no turn ever ran: the task was delivered and the session never started work on it (the pane showed: \"Use /login to log into a provider via OAuth or API key\")"
    screen: "Use /login to log into a provider via OAuth or API key\n"
    captured %9
    -> 0
    outcome failed "exit 1"
    screen: "Use /login to log into a provider via OAuth or API key\n"
    -> 0
    screen for completed: false
    |}]

(* The outcome write decides who speaks: without --unreported the child reported for itself, and a
   run already stopped from outside was spoken for by its stopper. *)
let%expect_test "run-outcome --unreported tells the parent once, and only if it won the write" =
  let dir = Filename.temp_dir "kido-state" "" in
  let inbox, received = start_inbox ~reply:"ok\n" in
  ignore (State.record ~dir "root-sess" (session ~pane:"%2" ~title:"orchestrator" ~inbox Idle));
  let child r = ignore (run ~dir ~name:"ttyfix" ~kind:Agent ~parent:"root-sess" r) in
  child "run-told";
  run_outcome ~dir ~unreported:true "completed" "run-told";
  child "run-self";
  run_outcome ~dir "completed" "run-self";
  child "run-stopped";
  outcome ~dir "run-stopped" Stopped;
  run_outcome ~dir ~unreported:true "completed" "run-stopped";
  List.iter (show_outcome ~dir) [ "run-told"; "run-self"; "run-stopped" ];
  List.iter
    (fun raw ->
      match Msg.parse raw with
      | Some e -> Printf.printf "%s from %s:\n%s\n" (Msg.string_of_kind e.kind) e.from.name e.text
      | None -> Printf.printf "not an envelope: %S\n" raw)
    (received ());
  [%expect
    {|
    -> 0
    -> 0
    -> 0
    outcome completed ""
    outcome completed ""
    outcome stopped ""
    notice from ttyfix:
    subagent "ttyfix" completed without reporting: it never called notify_parent, so this is the whole account of it
    run: run-told
    resume: spawn_subagent(resume: "run-told")
    |}]

(* Go's time.Duration printing, which the table and stop's escalation message carry. *)
let%expect_test "durations print as Go prints them" =
  List.iter
    (fun d -> Printf.printf "%g -> %s\n" d (Timestamp.duration d))
    [ 0.; 0.3; 1.; 1.5; 59.; 60.; 90.; 3600.; 3723.; 86400. ];
  [%expect
    {|
    0 -> 0s
    0.3 -> 300ms
    1 -> 1s
    1.5 -> 1.5s
    59 -> 59s
    60 -> 1m0s
    90 -> 1m30s
    3600 -> 1h0m0s
    3723 -> 1h2m3s
    86400 -> 24h0m0s
    |}]
