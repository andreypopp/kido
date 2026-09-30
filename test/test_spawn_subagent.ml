open Kido
open Fixture

let parent = "parent-sess"
let record ~dir id s = Result.get_exn (State.record ~dir id s)
let runs dir = Filename.concat dir "runs"

let flags : Spawn_subagent.flags =
  {
    parent_pid = 1;
    parent_session = parent;
    name = "kid";
    task_file = "";
    model = "";
    tools = "";
    resume = "";
    fork = "";
    keep_alive = false;
    no_parent = false;
    command = [];
  }

let resuming run = { flags with parent_pid = 0; parent_session = ""; name = ""; resume = run }

let task_file text =
  let path = Filename.temp_file "task" ".txt" in
  Fs.write path text;
  path

(* A state dir holding the caller, on %1, at [depth]. *)
let caller ?(depth = 0) () =
  let dir = Filename.temp_dir "kido-state" "" in
  record ~dir parent (session ~pane:"%1" ~depth Idle);
  dir

type fake = {
  tmux : Spawn_subagent.tmux;
  calls : (string * string * string * string list * string list) list ref;
  marks : (string * string) list ref;
  killed : string list ref;
}

let fake ?window_error ?mark_error ?(exists = true) () =
  let calls = ref [] and marks = ref [] and killed = ref [] in
  let tmux : Spawn_subagent.tmux =
    {
      new_window =
        (fun ~session ~name ~cwd ~env command ->
          calls := !calls @ [ (session, name, cwd, env, command) ];
          match window_error with
          | Some e -> Error e
          | None -> Ok { window_id = "@9"; pane_id = "%9"; pane_pid = 42424242 });
      mark_run =
        (fun pane run ->
          match mark_error with Some e -> Error e | None -> Ok (marks := (pane, run) :: !marks));
      window_exists = (fun _ -> exists);
      kill_window = (fun w -> Ok (killed := w :: !killed));
    }
  in
  { tmux; calls; marks; killed }

let models rows () = Ok (String.concat "\n" ("PROVIDER\tMODEL" :: rows) ^ "\n")

let pi ?(list_models = fun () -> failwith "pi --list-models must not run") ?(session_dir = "") () :
    Spawn_subagent.pi =
  { list_models; session_dir; agent_dir = ""; home = "" }

let panes = lazy (Ok [ pane ~session_id:"$1" ~cwd:"/work" "%1" ])

(* Fresh run ids, temp paths and this process's pid differ per run. *)
let scrub ~dir ids s =
  let pid = string_of_int (Unix.getpid ()) in
  List.fold_left
    (fun s (sub, by) -> String.replace ~sub ~by s)
    s
    ([
       (dir, "<dir>");
       (Filename.get_temp_dir_name (), "<tmp>");
       ("=" ^ pid, "=<pid>");
       ("pid " ^ pid, "pid <pid>");
     ]
    @ List.filter_map (fun id -> if String.length id = 32 then Some (id, "<run>") else None) ids)

let run_ids dir = List.map Subrun.string_of_id (Subrun.list ~dir:(runs dir))

let spawn ?(fake = fake ()) ?(pi = pi ()) ~dir flags =
  (match
     Result.flat_map
       (Spawn_subagent.spawn ~dir ~self:"%1" ~panes ~tmux:fake.tmux ~pi)
       (Spawn_subagent.parse flags)
   with
  | Ok line -> print_endline (scrub ~dir (run_ids dir) line)
  | Error m -> print_endline ("error: " ^ scrub ~dir (run_ids dir) (List.hd (String.lines m))));
  List.iter
    (fun (session, name, cwd, env, command) ->
      Printf.printf "new-window %s %S %s\n  env %s\n  cmd %s\n" session name cwd
        (scrub ~dir (run_ids dir) (String.concat " " env))
        (scrub ~dir (run_ids dir) (String.concat " " command)))
    !(fake.calls);
  fake.calls := []

let outcome dir id =
  match Subrun.read_outcome ~dir:(runs dir) (Result.get_exn (Subrun.parse_id id)) with
  | None -> "none"
  | Some { result = Failed; text; _ } -> "failed: " ^ text
  | Some { result = Completed | Died | Stopped; _ } -> "ended"

let meta dir id =
  Option.get_exn_or "meta" (Subrun.read_meta ~dir:(runs dir) (Result.get_exn (Subrun.parse_id id)))

(* pi/kido-agents.ts splits the one line on spaces; the mark is what makes the window reapable. *)
let%expect_test
    "a spawn prints window, pane and run, marks the pane, and never puts the task on a command line"
    =
  let dir = caller () in
  let fake = fake () in
  let secret = "secret task text\nwith $(a shell metachar)" in
  spawn ~fake ~dir { flags with task_file = task_file secret };
  let run = snd (List.hd !(fake.marks)) in
  Printf.printf "mark %s %b\n"
    (fst (List.hd !(fake.marks)))
    (String.equal run (List.hd (run_ids dir)));
  Printf.printf "task %b\n"
    (String.equal secret
       (Option.get_exn_or "task"
          (Fs.read (Filename.concat (Filename.concat (runs dir) run) "task"))));
  let m = meta dir run in
  Printf.printf "meta %s %s depth=%d parent=%s pane=%s pid=%d\n" m.name m.cwd m.depth
    m.parent_session m.pane m.pid;
  [%expect
    {|
    @9 %9 <run>
    new-window $1 "kid" /work
      env KIDO_AGENT_TASK_FILE=<dir>/runs/<run>/task KIDO_AGENT_RUN_ID=<run> KIDO_AGENT_DEPTH=1 KIDO_AGENT_PARENT_PID=1 KIDO_AGENT_PARENT_SESSION=parent-sess
      cmd pi --session-id <run>
    mark %9 true
    task true
    meta kid /work depth=1 parent=parent-sess pane=%9 pid=42424242
    |}]

let%expect_test "only the caller's own record sets the depth, and the ceiling holds" =
  List.iter
    (fun depth ->
      Printf.printf "caller at %d: " depth;
      spawn ~dir:(caller ~depth ()) { flags with task_file = task_file "x" })
    [ Spawn_subagent.max_depth; Spawn_subagent.max_depth - 1 ];
  (* No record on %1: depth 0, its child at 1. *)
  let dir = Filename.temp_dir "kido-state" "" in
  record ~dir parent (session ~pane:"%parent" Idle);
  print_string "unreported caller: ";
  spawn ~dir { flags with task_file = task_file "x"; command = [ "fakepi"; "--flag" ] };
  [%expect
    {|
    caller at 2: error: refusing to spawn at depth 3: maximum nesting is 2 (root 0, subagent 1, subagent 2)
    caller at 1: @9 %9 <run>
    new-window $1 "kid" /work
      env KIDO_AGENT_TASK_FILE=<dir>/runs/<run>/task KIDO_AGENT_RUN_ID=<run> KIDO_AGENT_DEPTH=2 KIDO_AGENT_PARENT_PID=1 KIDO_AGENT_PARENT_SESSION=parent-sess
      cmd pi --session-id <run>
    unreported caller: @9 %9 <run>
    new-window $1 "kid" /work
      env KIDO_AGENT_TASK_FILE=<dir>/runs/<run>/task KIDO_AGENT_RUN_ID=<run> KIDO_AGENT_DEPTH=1 KIDO_AGENT_PARENT_PID=1 KIDO_AGENT_PARENT_SESSION=parent-sess
      cmd fakepi --flag
    |}]

let%expect_test "names and task files are refused before any tmux call" =
  let dir = caller () in
  let task = task_file "x" in
  List.iter
    (fun name -> spawn ~dir { flags with name; task_file = task })
    [
      {|kid"s|};
      "kid$x";
      "kid#x";
      "kid`x";
      "kid\\x";
      "kid'x";
      "kid\nx";
      "kid\rx";
      String.make 65 'x';
    ];
  List.iter
    (fun task_file -> spawn ~dir { flags with task_file })
    [
      "/nonexistent/task.txt";
      Filename.get_temp_dir_name ();
      (let big = Filename.concat dir "big.txt" in
       Fs.write big (String.make (Spawn_subagent.max_task_bytes + 1) 'x');
       big);
    ];
  List.iter
    (fun t -> spawn ~dir { flags with name = "kid one"; task_file = t })
    [ task_file (String.make Spawn_subagent.max_task_bytes 'x') ];
  [%expect
    {|
    error: refusing window name "kid\"s": it contains "\"", which cannot survive tmux's own command-line parsing
    error: refusing window name "kid$x": it contains "$", which cannot survive tmux's own command-line parsing
    error: refusing window name "kid#x": it contains "#", which cannot survive tmux's own command-line parsing
    error: refusing window name "kid`x": it contains "`", which cannot survive tmux's own command-line parsing
    error: refusing window name "kid\\x": it contains "\\", which cannot survive tmux's own command-line parsing
    error: refusing window name "kid'x": it contains "'", which cannot survive tmux's own command-line parsing
    error: refusing window name "kid\nx": it contains "\n", which cannot survive tmux's own command-line parsing
    error: refusing window name "kid\rx": it contains "\r", which cannot survive tmux's own command-line parsing
    error: refusing window name "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx": 65 bytes is over the 64 byte limit
    error: --task-file "/nonexistent/task.txt": No such file or directory
    error: --task-file "<tmp>" is a directory, not a task file
    error: --task-file "<dir>/big.txt" is 1048577 bytes, over the 1048576 byte task limit
    @9 %9 <run>
    new-window $1 "kid one" /work
      env KIDO_AGENT_TASK_FILE=<dir>/runs/<run>/task KIDO_AGENT_RUN_ID=<run> KIDO_AGENT_DEPTH=1 KIDO_AGENT_PARENT_PID=1 KIDO_AGENT_PARENT_SESSION=parent-sess
      cmd pi --session-id <run>
    |}]

let%expect_test "a window or mark that fails is a failed run; a failed mark kills the window" =
  let show dir fake =
    List.iter (fun id -> print_endline (outcome dir id)) (run_ids dir);
    Printf.printf "killed [%s]\n" (String.concat " " !(fake.killed))
  in
  let dir = caller () in
  let f = fake ~window_error:"no such session" () in
  spawn ~fake:f ~dir { flags with task_file = task_file "x" };
  show dir f;
  let dir = caller () in
  let f = fake ~mark_error:"option failed" () in
  spawn ~fake:f ~dir { flags with task_file = task_file "x" };
  show dir f;
  (* An agent run has no wrapper to speak for it, so a window gone before its mark still fails. *)
  let dir = caller () in
  let f = fake ~mark_error:"cannot find window @9" ~exists:false () in
  spawn ~fake:f ~dir { flags with task_file = task_file "x" };
  show dir f;
  [%expect
    {|
    error: no such session
    new-window $1 "kid" /work
      env KIDO_AGENT_TASK_FILE=<dir>/runs/<run>/task KIDO_AGENT_RUN_ID=<run> KIDO_AGENT_DEPTH=1 KIDO_AGENT_PARENT_PID=1 KIDO_AGENT_PARENT_SESSION=parent-sess
      cmd pi --session-id <run>
    failed: no such session
    killed []
    error: option failed
    new-window $1 "kid" /work
      env KIDO_AGENT_TASK_FILE=<dir>/runs/<run>/task KIDO_AGENT_RUN_ID=<run> KIDO_AGENT_DEPTH=1 KIDO_AGENT_PARENT_PID=1 KIDO_AGENT_PARENT_SESSION=parent-sess
      cmd pi --session-id <run>
    failed: option failed
    killed [@9]
    error: cannot find window @9
    new-window $1 "kid" /work
      env KIDO_AGENT_TASK_FILE=<dir>/runs/<run>/task KIDO_AGENT_RUN_ID=<run> KIDO_AGENT_DEPTH=1 KIDO_AGENT_PARENT_PID=1 KIDO_AGENT_PARENT_SESSION=parent-sess
      cmd pi --session-id <run>
    failed: cannot find window @9
    killed [@9]
    |}]

(* The negative control for the agent case above: a bash run's own wrapper records and reports its
   ending, so a window that took the mark's chance with it is the ordinary ending it is. *)
let%expect_test "a bash run whose window is gone before its mark is not a failure" =
  let dir = Filename.temp_dir "kido-state" "" in
  let f = fake ~mark_error:"cannot find window @9" ~exists:false () in
  let id = Subrun.new_id () in
  Subrun.create ~dir:(runs dir) id "true";
  let m : Subrun.meta =
    {
      id;
      name = "build";
      kind = Some Bash;
      parent_session = parent;
      depth = 1;
      pane = "";
      pid = 0;
      cwd = "/work";
      model = "";
      tools = [];
      keep_alive = false;
      started_at = 0.;
    }
  in
  print_endline
    (scrub ~dir (run_ids dir)
       (Result.get_exn
          (Spawn_subagent.create_run_window ~runs:(runs dir) f.tmux m ~session:"$0" ~env:[]
             [ "kido"; "async-run" ])));
  Printf.printf "%s, killed [%s]\n"
    (outcome dir (Subrun.string_of_id id))
    (String.concat " " !(f.killed));
  [%expect {|
    @9 %9 <run> <dir>/runs/<run>/output
    none, killed []
    |}]

let%expect_test "--no-parent leaves no edge; a parent nobody holds, or both, is refused" =
  let dir = caller () in
  spawn ~dir
    {
      flags with
      parent_pid = 0;
      parent_session = "";
      no_parent = true;
      name = "loner";
      task_file = task_file "x";
    };
  List.iter
    (fun id -> Printf.printf "parentSession=%S\n" (meta dir id).parent_session)
    (run_ids dir);
  let dir = caller () in
  spawn ~dir { flags with parent_session = "nobody-is-this"; task_file = task_file "x" };
  spawn ~dir { flags with no_parent = true; task_file = task_file "x" };
  spawn ~dir { flags with parent_pid = 0; task_file = task_file "x" };
  [%expect
    {|
    @9 %9 <run>
    new-window $1 "loner" /work
      env KIDO_AGENT_TASK_FILE=<dir>/runs/<run>/task KIDO_AGENT_RUN_ID=<run> KIDO_AGENT_DEPTH=1
      cmd pi --session-id <run>
    parentSession=""
    error: --parent-session "nobody-is-this" names no currently live agent; the child would be closed within moments as an orphan (internal/reap's rule 2) - pass --no-parent for a child owned by nobody, or name an agent that is actually running
    error: --no-parent contradicts --parent-pid/--parent-session; pass one or the other
    error: --parent-pid and --parent-session name one parent and are given together
    |}]

(* pi 0.85.1: --fork and --session-id compose on the line, in this order, before the child's own
   flags. *)
let%expect_test
    "--fork goes onto the pi command line; a fork with a resume or an unsafe id is refused" =
  let dir = caller () in
  spawn ~dir { flags with task_file = task_file "merge"; fork = "caller-session-id" };
  spawn ~dir
    ~pi:(pi ~list_models:(models [ "acme\tclaude-sonnet-5" ]) ())
    {
      flags with
      task_file = task_file "x";
      fork = "caller-session-id";
      command = [ "pi"; "--name"; "kid"; "--model"; "acme/claude-sonnet-5" ];
    };
  let dir = caller () in
  spawn ~dir { (resuming "run-1") with fork = "sess-1" };
  spawn ~dir { flags with task_file = task_file "x"; fork = "sess$(id)" };
  [%expect
    {|
    @9 %9 <run>
    new-window $1 "kid" /work
      env KIDO_AGENT_TASK_FILE=<dir>/runs/<run>/task KIDO_AGENT_RUN_ID=<run> KIDO_AGENT_DEPTH=1 KIDO_AGENT_PARENT_PID=1 KIDO_AGENT_PARENT_SESSION=parent-sess
      cmd pi --fork caller-session-id --session-id <run>
    @9 %9 <run>
    new-window $1 "kid" /work
      env KIDO_AGENT_TASK_FILE=<dir>/runs/<run>/task KIDO_AGENT_RUN_ID=<run> KIDO_AGENT_DEPTH=1 KIDO_AGENT_PARENT_PID=1 KIDO_AGENT_PARENT_SESSION=parent-sess
      cmd pi --fork caller-session-id --session-id <run> --name kid --model acme/claude-sonnet-5
    error: --resume continues a run's own session; --fork starts a new one from somebody else's, and the two cannot both be asked for
    error: refusing --fork "sess$(id)": it contains "$", which cannot survive tmux's own command-line parsing
    |}]

let%expect_test "a model must be a configured provider's own, by exact provider/model" =
  let list = models [ "acme\tclaude-sonnet-5"; "acme  claude-opus-5"; "other\tgemini-pro" ] in
  List.iter
    (fun command ->
      Printf.printf "%s: %s\n" (String.concat " " command)
        (match Spawn_subagent.validate_model list command with Ok () -> "ok" | Error m -> m))
    [
      [ "pi"; "--model"; "acme/claude-sonnet-5" ];
      [ "pi"; "--model"; "sonnet" ];
      [ "pi"; "--model"; "claude-sonnet-5" ];
      [ "pi"; "--model"; "nope/claude-sonnet-5" ];
    ];
  (* No model, or a command that is not pi: pi --list-models is never run. *)
  let never () = failwith "never" in
  Result.get_exn (Spawn_subagent.validate_model never [ "pi" ]);
  Result.get_exn (Spawn_subagent.validate_model never [ "sh"; "--model"; "sonnet" ]);
  (match
     Spawn_subagent.validate_model
       (fun () -> Error {|exec: "pi": executable file not found in $PATH|})
       [ "pi"; "--model"; "acme/claude-sonnet-5" ]
   with
  | Ok () -> print_endline "ok"
  | Error m -> print_endline m);
  let dir = caller () in
  spawn ~dir
    ~pi:(pi ~list_models:(models [ "acme\tclaude-sonnet-5" ]) ())
    {
      flags with
      task_file = task_file "x";
      command = [ "pi"; "--name"; "kid"; "--model"; "sonnet" ];
    };
  [%expect
    {|
    pi --model acme/claude-sonnet-5: ok
    pi --model sonnet: model "sonnet" is not a model of a configured provider; configured: acme/{claude-sonnet-5,claude-opus-5}, other/{gemini-pro}
    pi --model claude-sonnet-5: model "claude-sonnet-5" is not a model of a configured provider; configured: acme/{claude-sonnet-5,claude-opus-5}, other/{gemini-pro}
    pi --model nope/claude-sonnet-5: model "nope/claude-sonnet-5" is not a model of a configured provider; configured: acme/{claude-sonnet-5,claude-opus-5}, other/{gemini-pro}
    could not validate model "acme/claude-sonnet-5": pi --list-models: exec: "pi": executable file not found in $PATH
    error: model "sonnet" is not a model of a configured provider; configured: acme/{claude-sonnet-5}
    |}]

(* pi/kido-status.ts delivers a session's first message too; one cap for both. *)
let%expect_test "the task cap is pi's MAX_PROMPT_BYTES" =
  let ts = Option.get_exn_or "ts" (Fs.read "../pi/kido-status.ts") in
  let line = List.find (String.prefix ~pre:"const MAX_PROMPT_BYTES = ") (String.lines ts) in
  print_endline line;
  Printf.printf "%d\n" Spawn_subagent.max_task_bytes;
  [%expect {|
    const MAX_PROMPT_BYTES = 1024 * 1024;
    1048576
    |}]

(* pi names a session file "<timestamp>_<id>.jsonl". *)
let session_dir ids =
  let d = Filename.temp_dir "pi-sessions" "" in
  List.iter
    (fun id -> Fs.write (Filename.concat d ("2026-01-01T00-00-00-000Z_" ^ id ^ ".jsonl")) "{}")
    ids;
  d

let dead_run ?(model = "") ?(pid = dead_pid ()) dir id =
  let id = Result.get_exn (Subrun.parse_id id) in
  Subrun.create ~dir:(runs dir) id "do the thing";
  Subrun.write_meta ~dir:(runs dir)
    {
      id;
      name = "kid";
      kind = None;
      parent_session = "old-parent";
      depth = 1;
      pane = "%1";
      pid;
      cwd = "/runcwd";
      model;
      tools = [];
      keep_alive = false;
      started_at = 1_700_000_000.;
    };
  if pid <> Unix.getpid () then
    ignore (Subrun.record_outcome ~dir:(runs dir) id { result = Died; text = ""; at = None })

let%expect_test "a resume refuses an unknown run, a live one, and a name, task or half a parent" =
  let dir = caller () in
  dead_run ~pid:(Unix.getpid ()) dir "live-run";
  spawn ~dir (resuming "no-such-run");
  spawn ~dir (resuming "live-run");
  spawn ~dir { (resuming "x") with name = "kid" };
  spawn ~dir { (resuming "x") with task_file = "/tmp/task" };
  spawn ~dir { (resuming "x") with parent_pid = 1 };
  spawn
    ~dir:(caller ~depth:Spawn_subagent.max_depth ())
    { (resuming "deep-run") with parent_pid = 1; parent_session = "p" };
  let dir = caller () in
  dead_run dir "orphan-run";
  spawn ~dir { (resuming "orphan-run") with parent_pid = 777; parent_session = "nobody-is-this" };
  [%expect
    {|
    error: run "no-such-run": no readable <dir>/runs/no-such-run/meta.json
    error: run "live-run" is still running (pid <pid>); resuming a live agent makes no sense
    error: --resume keeps the run's original window name; --name is refused alongside it
    error: --resume keeps the run's original task; --task-file is refused alongside it
    error: --parent-pid and --parent-session name one parent and are given together
    error: refusing to spawn at depth 3: maximum nesting is 2 (root 0, subagent 1, subagent 2)
    error: --parent-session "nobody-is-this" names no currently live agent; the child would be closed within moments as an orphan (internal/reap's rule 2) - pass --no-parent for a child owned by nobody, or name an agent that is actually running
    |}]

let%expect_test "a resume continues the run's own session, cwd, id and task under a new parent" =
  let dir = caller () in
  record ~dir "new-parent" (session ~pane:"%other" Idle);
  dead_run dir "resume-run";
  Subrun.write_screen ~dir:(runs dir)
    (Result.get_exn (Subrun.parse_id "resume-run"))
    "first attempt";
  let pi = pi ~session_dir:(session_dir [ "resume-run" ]) () in
  spawn ~pi ~dir { (resuming "resume-run") with parent_pid = 777; parent_session = "new-parent" };
  let m = meta dir "resume-run" in
  Printf.printf "meta %s started=%.0f parent=%s pane=%s pid=%d depth=%d\n" m.name m.started_at
    m.parent_session m.pane m.pid m.depth;
  let id = Result.get_exn (Subrun.parse_id "resume-run") in
  Printf.printf "task=%s outcome=%s screen=%b\n"
    (Option.get_or ~default:"" (Subrun.read_task ~dir:(runs dir) id))
    (outcome dir "resume-run")
    (Option.is_some (Subrun.read_screen ~dir:(runs dir) id));
  (* No parent flags: the caller's own record is the edge; --no-parent drops even that. *)
  let dir = caller () in
  dead_run dir "defaulted";
  let pi = Spawn_subagent.{ pi with session_dir = session_dir [ "defaulted"; "handed-over" ] } in
  spawn ~pi ~dir (resuming "defaulted");
  dead_run dir "handed-over";
  spawn ~pi ~dir { (resuming "handed-over") with no_parent = true };
  Printf.printf "parentSession=%S\n" (meta dir "handed-over").parent_session;
  [%expect
    {|
    @9 %9 resume-run
    new-window $1 "kid" /runcwd
      env KIDO_AGENT_TASK_FILE=<dir>/runs/resume-run/task KIDO_AGENT_RUN_ID=resume-run KIDO_AGENT_DEPTH=1 KIDO_AGENT_PARENT_PID=777 KIDO_AGENT_PARENT_SESSION=new-parent
      cmd pi --session resume-run
    meta kid started=1700000000 parent=new-parent pane=%9 pid=42424242 depth=1
    task=do the thing outcome=none screen=false
    @9 %9 defaulted
    new-window $1 "kid" /runcwd
      env KIDO_AGENT_TASK_FILE=<dir>/runs/defaulted/task KIDO_AGENT_RUN_ID=defaulted KIDO_AGENT_DEPTH=1 KIDO_AGENT_PARENT_PID=<pid> KIDO_AGENT_PARENT_SESSION=parent-sess
      cmd pi --session defaulted
    @9 %9 handed-over
    new-window $1 "kid" /runcwd
      env KIDO_AGENT_TASK_FILE=<dir>/runs/handed-over/task KIDO_AGENT_RUN_ID=handed-over KIDO_AGENT_DEPTH=1
      cmd pi --session handed-over
    parentSession=""
    |}]

(* With no pi session file the id is free, not stale: --session-id mints a session under it and the
   delivered marker goes, so the stored task is delivered again. *)
let%expect_test "a resume with no pi session file mints one under the same run id" =
  let dir = caller () in
  dead_run dir "gone-run";
  let id = Result.get_exn (Subrun.parse_id "gone-run") in
  Fs.write (Subrun.delivered_path ~dir:(runs dir) id) "";
  spawn ~pi:(pi ~session_dir:(session_dir []) ()) ~dir (resuming "gone-run");
  Printf.printf "delivered=%b\n" (Sys.file_exists (Subrun.delivered_path ~dir:(runs dir) id));
  [%expect
    {|
    @9 %9 gone-run
    new-window $1 "kid" /runcwd
      env KIDO_AGENT_TASK_FILE=<dir>/runs/gone-run/task KIDO_AGENT_RUN_ID=gone-run KIDO_AGENT_DEPTH=1 KIDO_AGENT_PARENT_PID=<pid> KIDO_AGENT_PARENT_SESSION=parent-sess
      cmd pi --session-id gone-run
    delivered=false
    |}]

let%expect_test "a resume carries the run's model, tools and keep-alive unless given anew" =
  let list_models = models [ "acme\tclaude-sonnet-5"; "acme\tclaude-opus-5" ] in
  let dir = caller () in
  let sessions = session_dir [ "modeled"; "modeled-2" ] in
  let pi = pi ~list_models ~session_dir:sessions () in
  dead_run ~model:"acme/claude-sonnet-5" dir "modeled";
  spawn ~pi ~dir (resuming "modeled");
  dead_run ~model:"acme/claude-sonnet-5" dir "modeled-2";
  spawn ~pi ~dir { (resuming "modeled-2") with command = [ "pi"; "--model"; "acme/claude-opus-5" ] };
  (* Recorded by a real fresh spawn, so dropping either the recording or the carrying fails. *)
  let dir = caller () in
  let f = fake () in
  spawn ~fake:f ~pi ~dir
    {
      flags with
      name = "helper";
      task_file = task_file "hold";
      model = "acme/claude-sonnet-5";
      tools = "read,bash";
      keep_alive = true;
    };
  let run = snd (List.hd !(f.marks)) in
  ignore
    (Subrun.record_outcome ~dir:(runs dir)
       (Result.get_exn (Subrun.parse_id run))
       { result = Completed; text = ""; at = None });
  let pi = Spawn_subagent.{ pi with session_dir = session_dir [ run ] } in
  spawn ~pi ~dir { (resuming run) with parent_pid = 1; parent_session = parent };
  Printf.printf "keepAlive=%b\n" (meta dir run).keep_alive;
  (* Recorded without them: none invented, and an explicit --keep-alive still goes through. *)
  let dir = caller () in
  dead_run dir "old-run";
  let pi = Spawn_subagent.{ pi with session_dir = session_dir [ "old-run" ] } in
  spawn ~pi ~dir { (resuming "old-run") with parent_pid = 1; parent_session = parent };
  let id = Result.get_exn (Subrun.parse_id "old-run") in
  Subrun.reset_for_resume ~dir:(runs dir) id ~delivered:false;
  ignore (Subrun.record_outcome ~dir:(runs dir) id { result = Died; text = ""; at = None });
  spawn ~pi ~dir
    { (resuming "old-run") with parent_pid = 1; parent_session = parent; keep_alive = true };
  [%expect
    {|
    @9 %9 modeled
    new-window $1 "kid" /runcwd
      env KIDO_AGENT_TASK_FILE=<dir>/runs/modeled/task KIDO_AGENT_RUN_ID=modeled KIDO_AGENT_DEPTH=1 KIDO_AGENT_PARENT_PID=<pid> KIDO_AGENT_PARENT_SESSION=parent-sess
      cmd pi --session modeled --model acme/claude-sonnet-5
    @9 %9 modeled-2
    new-window $1 "kid" /runcwd
      env KIDO_AGENT_TASK_FILE=<dir>/runs/modeled-2/task KIDO_AGENT_RUN_ID=modeled-2 KIDO_AGENT_DEPTH=1 KIDO_AGENT_PARENT_PID=<pid> KIDO_AGENT_PARENT_SESSION=parent-sess
      cmd pi --session modeled-2 --model acme/claude-opus-5
    @9 %9 <run>
    new-window $1 "helper" /work
      env KIDO_AGENT_TASK_FILE=<dir>/runs/<run>/task KIDO_AGENT_RUN_ID=<run> KIDO_AGENT_DEPTH=1 KIDO_AGENT_PARENT_PID=1 KIDO_AGENT_PARENT_SESSION=parent-sess KIDO_AGENT_KEEP_ALIVE=1
      cmd pi --session-id <run>
    @9 %9 <run>
    new-window $1 "helper" /work
      env KIDO_AGENT_TASK_FILE=<dir>/runs/<run>/task KIDO_AGENT_RUN_ID=<run> KIDO_AGENT_DEPTH=1 KIDO_AGENT_PARENT_PID=1 KIDO_AGENT_PARENT_SESSION=parent-sess KIDO_AGENT_KEEP_ALIVE=1
      cmd pi --session <run> --model acme/claude-sonnet-5 --tools read,bash
    keepAlive=true
    @9 %9 old-run
    new-window $1 "kid" /runcwd
      env KIDO_AGENT_TASK_FILE=<dir>/runs/old-run/task KIDO_AGENT_RUN_ID=old-run KIDO_AGENT_DEPTH=1 KIDO_AGENT_PARENT_PID=1 KIDO_AGENT_PARENT_SESSION=parent-sess
      cmd pi --session old-run
    @9 %9 old-run
    new-window $1 "kid" /runcwd
      env KIDO_AGENT_TASK_FILE=<dir>/runs/old-run/task KIDO_AGENT_RUN_ID=old-run KIDO_AGENT_DEPTH=1 KIDO_AGENT_PARENT_PID=1 KIDO_AGENT_PARENT_SESSION=parent-sess KIDO_AGENT_KEEP_ALIVE=1
      cmd pi --session old-run
    |}]

let%expect_test "a resume's failed window or mark is a failed run, its meta left alone" =
  let dir = caller () in
  dead_run dir "windowless";
  let pi = pi ~session_dir:(session_dir [ "windowless"; "unmarkable" ]) () in
  let before = Subrun.meta_to_yojson (meta dir "windowless") in
  spawn ~pi ~fake:(fake ~window_error:"no such session" ()) ~dir (resuming "windowless");
  Printf.printf "%s, meta unchanged=%b\n" (outcome dir "windowless")
    (Yojson.Safe.equal before (Subrun.meta_to_yojson (meta dir "windowless")));
  dead_run dir "unmarkable";
  let f = fake ~mark_error:"option failed" () in
  spawn ~pi ~fake:f ~dir (resuming "unmarkable");
  Printf.printf "%s, killed [%s]\n" (outcome dir "unmarkable") (String.concat " " !(f.killed));
  [%expect
    {|
    error: no such session
    new-window $1 "kid" /runcwd
      env KIDO_AGENT_TASK_FILE=<dir>/runs/windowless/task KIDO_AGENT_RUN_ID=windowless KIDO_AGENT_DEPTH=1 KIDO_AGENT_PARENT_PID=<pid> KIDO_AGENT_PARENT_SESSION=parent-sess
      cmd pi --session windowless
    failed: no such session, meta unchanged=true
    error: option failed
    new-window $1 "kid" /runcwd
      env KIDO_AGENT_TASK_FILE=<dir>/runs/unmarkable/task KIDO_AGENT_RUN_ID=unmarkable KIDO_AGENT_DEPTH=1 KIDO_AGENT_PARENT_PID=<pid> KIDO_AGENT_PARENT_SESSION=parent-sess
      cmd pi --session unmarkable
    failed: option failed, killed [@9]
    |}]
