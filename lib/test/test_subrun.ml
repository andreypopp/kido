open Kido
open Fixture

let temp () = Filename.temp_dir "kido-state" ""
let id s = Result.get_exn (Subrun.parse_id s)
let in_run ~dir i name = Filename.concat (Filename.dirname (Subrun.task_path ~dir i)) name

let%expect_test "Create writes meta and task, round-tripping what was written" =
  let dir = temp () in
  let i = id "run-1" in
  Subrun.create ~dir i "do the thing";
  Subrun.write_meta ~dir
    {
      id = i;
      name = "kid";
      kind = Agent;
      parent_session = "";
      depth = 1;
      pane = "%1";
      pid = 0;
      cwd = "/tmp";
      model = "";
      tools = [];
      keep_alive = false;
      started_at = Timestamp.now ();
    };
  let got = Option.get_exn_or "ReadMeta" (Subrun.read_meta ~dir i) in
  Printf.printf "%s %d %s\n" got.name got.depth got.pane;
  print_endline (Option.get_exn_or "ReadTask" (Subrun.read_task ~dir i));
  Printf.printf "run dir exists: %b\n" (Sys.file_exists (Filename.concat dir "runs/run-1"));
  [%expect {|
    kid 1 %1
    do the thing
    run dir exists: true
    |}]

let%expect_test "Kind round-trips" =
  let dir = temp () in
  let show name k =
    let i = id name in
    Subrun.create ~dir i "x";
    Subrun.write_meta ~dir
      {
        id = i;
        name;
        kind = k;
        parent_session = "";
        depth = 0;
        pane = "";
        pid = 0;
        cwd = "";
        model = "";
        tools = [];
        keep_alive = false;
        started_at = 0.;
      };
    let got = Option.get_exn_or "ReadMeta" (Subrun.read_meta ~dir i) in
    Printf.printf "%s %s\n" name (Subrun.string_of_kind got.kind)
  in
  show "run-bash" Subrun.Bash;
  show "run-agent" Subrun.Agent;
  show "run-stream" Subrun.Stream;
  [%expect {|
    run-bash bash
    run-agent agent
    run-stream stream
    |}]

let%expect_test "Command round-trips exactly, and an empty command is refused" =
  let dir = temp () in
  let i = id "run-cmd" in
  Subrun.create ~dir i "x";
  Printf.printf "no command written: %b\n" (Option.is_none (Subrun.read_command ~dir i));
  let argv = [ "bash"; "-c"; "echo 'it\"s' $HOME `date`\nexit 3" ] in
  Subrun.write_command ~dir i argv;
  let got = Option.get_exn_or "ReadCommand" (Subrun.read_command ~dir i) in
  Printf.printf "round-trips: %b\n" (List.equal String.equal got argv);
  Subrun.write_command ~dir i [];
  Printf.printf "empty command refused: %b\n" (Option.is_none (Subrun.read_command ~dir i));
  [%expect
    {|
    no command written: true
    round-trips: true
    empty command refused: true
    |}]

let%expect_test "RecordOutcome writes once; a later write is refused and the first stands" =
  let dir = temp () in
  let i = id "run-3" in
  Subrun.create ~dir i "x";
  let wrote_first =
    Subrun.record_outcome ~dir i { result = Completed; text = ""; at = Some (Timestamp.now ()) }
  in
  let wrote_second =
    Subrun.record_outcome ~dir i { result = Died; text = ""; at = Some (Timestamp.now ()) }
  in
  let got = Option.get_exn_or "ReadOutcome" (Subrun.read_outcome ~dir i) in
  Printf.printf "%b %b %s\n" wrote_first wrote_second
    (match got.result with Completed -> "completed" | _ -> "wrong");
  Sys.readdir (Filename.dirname (Subrun.task_path ~dir i))
  |> Array.to_list |> List.sort String.compare |> List.iter print_endline;
  [%expect {|
    true false completed
    outcome
    task
    |}]

let%expect_test "RecordOutcome into a run directory that is gone lost the write, not an error" =
  let i = id "run-missing" in
  Printf.printf "%b\n"
    (Subrun.record_outcome ~dir:(temp ()) i { result = Died; text = ""; at = None });
  [%expect {| false |}]

let%expect_test "ResetForResume clears outcome, screen, and (when asked) the delivered marker" =
  let dir = temp () in
  let i = id "run-screen-clear" in
  Subrun.create ~dir i "x";
  Subrun.reset_for_resume ~dir i ~delivered:true;
  Fs.write (in_run ~dir i "screen") "captured";
  ignore (Subrun.record_outcome ~dir i { result = Died; text = ""; at = None });
  Fs.write (in_run ~dir i "delivered") "";
  Subrun.reset_for_resume ~dir i ~delivered:true;
  Printf.printf "screen gone: %b\n" (Option.is_none (Subrun.read_screen ~dir i));
  Printf.printf "outcome gone: %b\n" (Option.is_none (Subrun.read_outcome ~dir i));
  Printf.printf "delivered gone: %b\n" (not (Sys.file_exists (in_run ~dir i "delivered")));
  [%expect {|
    screen gone: true
    outcome gone: true
    delivered gone: true
    |}]

let%expect_test "ResetForResume keeps the delivered marker unless asked" =
  let dir = temp () in
  let i = id "run-screen-clear-2" in
  Subrun.create ~dir i "x";
  Fs.write (in_run ~dir i "delivered") "";
  Subrun.reset_for_resume ~dir i ~delivered:false;
  Printf.printf "delivered kept: %b\n" (Sys.file_exists (in_run ~dir i "delivered"));
  [%expect {| delivered kept: true |}]

let%expect_test "EffectiveOutcome: still running when alive and unrecorded" =
  let dir = temp () in
  let i = id "run-4" in
  Subrun.create ~dir i "x";
  Printf.printf "%b\n" (Option.is_none (Subrun.effective_outcome ~dir i ~pid:(Unix.getpid ())));
  [%expect {| true |}]

let%expect_test "EffectiveOutcome: Died when dead and unrecorded, never Completed" =
  let dir = temp () in
  let i = id "run-5" in
  Subrun.create ~dir i "x";
  let got =
    Option.get_exn_or "EffectiveOutcome" (Subrun.effective_outcome ~dir i ~pid:(dead_pid ()))
  in
  Printf.printf "%s\n" (match got.result with Died -> "died" | _ -> "wrong");
  [%expect {| died |}]

let%expect_test "EffectiveOutcome prefers a recorded outcome over a guess" =
  let dir = temp () in
  let i = id "run-6" in
  Subrun.create ~dir i "x";
  ignore
    (Subrun.record_outcome ~dir i { result = Stopped; text = ""; at = Some (Timestamp.now ()) });
  let got =
    Option.get_exn_or "EffectiveOutcome" (Subrun.effective_outcome ~dir i ~pid:(dead_pid ()))
  in
  Printf.printf "%s\n" (match got.result with Stopped -> "stopped" | _ -> "wrong");
  [%expect {| stopped |}]

let%expect_test "List returns the run directories under dir" =
  let dir = temp () in
  Subrun.create ~dir (id "a") "x";
  Subrun.create ~dir (id "b") "x";
  Printf.printf "%d\n" (List.length (Subrun.list ~dir));
  [%expect {| 2 |}]

let%expect_test "ReadMeta: missing, truncated, or malformed JSON each read as None, not a crash" =
  let dir = temp () in
  let i = id "run-bad" in
  Subrun.create ~dir i "x";
  Printf.printf "no meta written: %b\n" (Option.is_none (Subrun.read_meta ~dir i));
  Fs.write (Subrun.meta_path ~dir i) {|{"id":"run-bad","name":|};
  Printf.printf "truncated: %b\n" (Option.is_none (Subrun.read_meta ~dir i));
  Fs.write (Subrun.meta_path ~dir i) {|["not", "an", "object"]|};
  Printf.printf "array: %b\n" (Option.is_none (Subrun.read_meta ~dir i));
  [%expect {|
    no meta written: true
    truncated: true
    array: true
    |}]

let%expect_test "ParseID refuses path traversal" =
  List.iter
    (fun s -> Printf.printf "%-10S %b\n" s (Result.is_error (Subrun.parse_id s)))
    [ ""; "."; ".."; "../evil"; "a/b"; "..\\evil"; ".hidden" ];
  [%expect
    {|
    ""         true
    "."        true
    ".."       true
    "../evil"  true
    "a/b"      true
    "..\\evil" true
    ".hidden"  true
    |}]

let%expect_test "screen truncation keeps the tail" =
  let short = String.repeat "x" 100 in
  Printf.printf "short unchanged: %b\n" (String.equal short (Subrun.truncate_screen short));
  let long = String.repeat "x" 10 ^ String.repeat "y" (64 * 1024) in
  let truncated = Subrun.truncate_screen long in
  Printf.printf "%d %b\n" (String.length truncated)
    (String.equal (String.repeat "y" (64 * 1024)) truncated);
  [%expect {|
    short unchanged: true
    65536 true
    |}]
