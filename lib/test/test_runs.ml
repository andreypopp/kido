open Kido
open Fixture

let attempt = function Ok () -> () | Error m -> Printf.printf "refused: %s\n" m
let id s = Result.get_exn (Subrun.parse_id s)

let outcome ~dir run result =
  ignore (Subrun.record_outcome ~dir (id run) { result; text = ""; at = Some 1_700_000_090. })

let show_outcome ~dir run =
  match Subrun.read_outcome ~dir (id run) with
  | None -> print_endline "no outcome"
  | Some o -> Printf.printf "outcome %s %S\n" (Subrun.string_of_result o.result) o.text

let%expect_test "runs: the table newest first, one run shown, and --json" =
  let dir = Filename.temp_dir "kido-state" "" in
  ignore
    (run ~dir ~name:"kid" ~kind:Agent ~parent:"root" ~cwd:"/tmp/some project"
       ~started_at:1_700_000_000. "run-a");
  outcome ~dir "run-a" Completed;
  ignore (run ~dir ~name:"later" ~kind:Bash ~pid:(dead_pid ()) ~started_at:1_700_003_600. "run-b");
  let local out =
    List.fold_left
      (fun out (t, name) -> String.replace ~sub:(Timestamp.to_local_string t) ~by:name out)
      out
      [
        (1_700_000_000., "<started a>");
        (1_700_000_090., "<ended a>");
        (1_700_003_600., "<started b>");
      ]
  in
  (* Local time, whatever this machine's zone. *)
  Runs.table ~now:(Timestamp.now ()) (Runs.list ~dir ())
  |> List.iter (fun row ->
      List.filter (Fun.negate String.is_empty) row |> String.concat " | " |> local |> print_endline);
  print_string (local (Result.get_exn (Runs.show ~dir ~json:false "run-a")));
  [%expect
    {|
    ID | NAME | PARENT | STARTED | DURATION | OUTCOME | CWD
    run-b | later | <started b> | - | died
    run-a | kid | root | <started a> | 1m30s | completed | /tmp/some project
    id:       run-a
    name:     kid
    kind:     agent
    parent:   root
    depth:    1
    cwd:      /tmp/some project
    started:  <started a>
    outcome:  completed
    ended:    <ended a>
    resume:   cd '/tmp/some project' && kido tool spawn_subagent --resume run-a
    fork:     cd '/tmp/some project' && pi --fork run-a
    task:
    do the thing
    |}];
  let shown = Yojson.Safe.from_string (Result.get_exn (Runs.show ~dir ~json:true "run-a")) in
  let listed = `List (List.map Runs.info_to_yojson (Runs.list ~dir ())) in
  Yojson.Safe.Util.(
    print_endline (String.concat " " (keys shown));
    List.iter
      (fun r ->
        Printf.printf "%s %s\n"
          (to_string (member "id" r))
          (match member "outcome" r with `Null -> "running" | o -> to_string (member "result" o)))
      (to_list listed));
  [%expect
    {|
    id name kind parentSession depth pane pid cwd startedAt outcome task resume fork
    run-b died
    run-a completed
    |}]

let%expect_test "runs: filter by parent, still newest first" =
  let dir = Filename.temp_dir "kido-state" "" in
  ignore (run ~dir ~parent:"root" ~started_at:1. "old");
  ignore (run ~dir ~parent:"other" ~started_at:3. "other");
  ignore (run ~dir ~parent:"root" ~pid:(Unix.getpid ()) ~started_at:2. "new");
  outcome ~dir "old" Completed;
  Runs.list ~parent_session:"root" ~dir ()
  |> List.iter (fun (r : Runs.info) ->
      Printf.printf "%s %s\n" (Subrun.string_of_id r.meta.id)
        (Option.map_or ~default:"running"
           (fun o -> Subrun.string_of_result o.Subrun.result)
           r.outcome));
  [%expect {|
    new running
    old completed
    |}]

let%expect_test "runs: running while the run's process lives, died once it is gone" =
  let dir = Filename.temp_dir "kido-state" "" in
  ignore (run ~dir ~pid:(Unix.getpid ()) "run-live");
  ignore (run ~dir ~pid:(dead_pid ()) "run-dead");
  List.concat_map
    (fun r ->
      String.lines (Result.get_exn (Runs.show ~dir ~json:false r))
      |> List.filter (String.prefix ~pre:"outcome:"))
    [ "run-live"; "run-dead" ]
  |> List.iter print_endline;
  [%expect {|
    outcome:  running
    outcome:  died
    |}]

let run_outcome ~dir ?(unreported = false) result r =
  attempt
    (Runs.run_outcome ~dir ~warn:(Printf.printf "warning: %s\n") ~result ~text:"" ~unreported r)

let%expect_test "run-outcome records one outcome, and only for a valid run id" =
  let dir = Filename.temp_dir "kido-state" "" in
  ignore (run ~dir ~pane:"%9" "run-x");
  show_outcome ~dir "run-x";
  run_outcome ~dir Completed "run-x";
  show_outcome ~dir "run-x";
  run_outcome ~dir Completed "run-x";
  run_outcome ~dir Completed "../escape";
  [%expect
    {|
    no outcome
    outcome completed ""
    refused: run run-x already has an outcome, or is gone
    refused: invalid run id "../escape"
    |}]

(* The outcome write decides who speaks: without --unreported the child reported for itself, and a
   run already stopped from outside was spoken for by its stopper. *)
let%expect_test "run-outcome --unreported tells the parent once, and only if it won the write" =
  let dir = Filename.temp_dir "kido-state" "" in
  let inbox, received = start_inbox ~reply:"ok\n" in
  ignore (State.record ~dir "root-sess" (session ~pane:"%2" ~inbox ()));
  let child r = ignore (run ~dir ~name:"ttyfix" ~kind:Agent ~parent:"root-sess" r) in
  child "run-told";
  run_outcome ~dir ~unreported:true Completed "run-told";
  child "run-self";
  run_outcome ~dir Completed "run-self";
  child "run-stopped";
  outcome ~dir "run-stopped" Stopped;
  run_outcome ~dir ~unreported:true Completed "run-stopped";
  List.iter (show_outcome ~dir) [ "run-told"; "run-self"; "run-stopped" ];
  List.iter
    (fun raw ->
      match Fixture.envelope raw with
      | Some e -> Printf.printf "%s from %s:\n%s\n" (e "kind") (e "from.name") (e "text")
      | None -> Printf.printf "not an envelope: %S\n" raw)
    (received ());
  [%expect
    {|
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
