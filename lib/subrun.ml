type id = string [@@deriving yojson]

let parse_id s =
  if
    String.is_empty s || String.mem ~sub:"/" s || String.mem ~sub:"\\" s || String.prefix ~pre:"." s
  then Error (Printf.sprintf "invalid run id %S" s)
  else Ok s

let new_id () = Msg.new_id ()
let string_of_id (id : id) = id
let runs dir = Filename.concat dir "runs"
let dir_for ~dir id = Filename.concat (runs dir) id
let task_path ~dir id = Filename.concat (dir_for ~dir id) "task"
let command_path ~dir id = Filename.concat (dir_for ~dir id) "command"
let output_path ~dir id = Filename.concat (dir_for ~dir id) "output"
let report_path ~dir id = Filename.concat (dir_for ~dir id) "report"
let delivered_path ~dir id = Filename.concat (dir_for ~dir id) "delivered"
let meta_path ~dir id = Filename.concat (dir_for ~dir id) "meta.json"
let outcome_path ~dir id = Filename.concat (dir_for ~dir id) "outcome"
let screen_path ~dir id = Filename.concat (dir_for ~dir id) "screen"

type kind = Agent | Bash | Stream

let string_of_kind = function Agent -> "agent" | Bash -> "bash" | Stream -> "stream"
let kinds = [ ("agent", Agent); ("bash", Bash); ("stream", Stream) ]
let kind_to_yojson k = `String (string_of_kind k)

let kind_of_yojson = function
  | `String s -> Option.to_result ("unknown kind " ^ s) (List.assoc_opt ~eq:String.equal s kinds)
  | _ -> Error "kind"

type meta = {
  id : id;
  name : string;
  kind : kind;
  parent_session : string; [@key "parentSession"] [@default ""]
  depth : int;
  pane :
    (Tmux.Pane.id option
    [@to_yojson Tmux.Pane.optional_id_to_yojson] [@of_yojson Tmux.Pane.optional_id_of_yojson]);
  pid : int;
  cwd : string;
  model : string; [@default ""]
  tools : string list; [@default []]
  keep_alive : bool; [@key "keepAlive"] [@default false]
  started_at : Timestamp.t; [@key "startedAt"]
}
[@@deriving yojson]

let label m = if String.is_empty m.name then string_of_id m.id else m.name

type result = Completed | Failed | Died | Stopped

let string_of_result = function
  | Completed -> "completed"
  | Failed -> "failed"
  | Died -> "died"
  | Stopped -> "stopped"

let results = List.map (fun r -> (string_of_result r, r)) [ Completed; Failed; Died; Stopped ]
let result_to_yojson r = `String (string_of_result r)

let result_of_yojson = function
  | `String s ->
      Option.to_result ("unknown result " ^ s) (List.assoc_opt ~eq:String.equal s results)
  | _ -> Error "result"

type outcome = {
  result : result;
  text : string; [@default ""]
  at : Timestamp.t option; [@default None]
}
[@@deriving yojson { strict = false }]

let create ~dir id task =
  Fs.mkdir_p ~perm:0o700 (dir_for ~dir id);
  Fs.write ~perm:0o600 (task_path ~dir id) task

type command = string list [@@deriving yojson]

let read_json path of_yojson =
  Option.flat_map
    (fun raw ->
      match Yojson.Safe.from_string raw with
      | exception Yojson.Json_error _ -> None
      | json -> Result.to_opt (of_yojson json))
    (Fs.read path)

let write_command ~dir id argv =
  Fs.write ~perm:0o600 (command_path ~dir id) (Yojson.Safe.to_string (command_to_yojson argv))

let read_command ~dir id =
  match read_json (command_path ~dir id) command_of_yojson with Some [] | None -> None | c -> c

let write_meta ~dir m =
  Fs.mkdir_p ~perm:0o700 (dir_for ~dir m.id);
  Fs.write_atomic (meta_path ~dir m.id) (Yojson.Safe.to_string (meta_to_yojson m))

let read_meta ~dir id = read_json (meta_path ~dir id) meta_of_yojson
let write_report ~dir id text = Fs.write_atomic ~perm:0o600 (report_path ~dir id) text
let has_report ~dir id = Sys.file_exists (report_path ~dir id)
let read_task ~dir id = Fs.read (task_path ~dir id)

let record_outcome ~dir id o =
  match
    Fs.write_temp (outcome_path ~dir id) (Yojson.Safe.to_string (outcome_to_yojson o)) Unix.link
  with
  | () -> true
  | exception Unix.Unix_error _ -> false

let read_screen ~dir id = Fs.read (screen_path ~dir id)

let reset_for_resume ~dir id ~delivered =
  let paths = [ outcome_path ~dir id; screen_path ~dir id ] in
  let paths = if delivered then paths @ [ delivered_path ~dir id ] else paths in
  List.iter Fs.remove paths

let read_outcome ~dir id = read_json (outcome_path ~dir id) outcome_of_yojson

let effective_outcome ~dir id ~pid =
  match read_outcome ~dir id with
  | Some _ as o -> o
  | None -> if State.alive pid then None else Some { result = Died; text = ""; at = None }

let list ~dir =
  let runs = runs dir in
  match Sys.readdir runs with
  | exception Sys_error _ -> []
  | names ->
      Array.sort String.compare names;
      Array.to_list names |> List.filter (fun name -> Sys.is_directory (Filename.concat runs name))

let max_screen_bytes = 64 * 1024

let truncate_screen data =
  let n = String.length data in
  if n > max_screen_bytes then String.sub data (n - max_screen_bytes) max_screen_bytes else data

let save_screen ?socket ~dir id pane =
  Option.flat_map
    (fun pane ->
      Option.map
        (fun text ->
          let data = truncate_screen text in
          (if not (String.is_empty data) then
             try Fs.write_atomic (screen_path ~dir id) data
             with Unix.Unix_error _ | Sys_error _ -> ());
          data)
        (Result.to_opt (Tmux.Exec.capture_screen ?socket pane)))
    pane

let%test_module "Tests" =
  (module struct
    open Test_support

    let temp () = Filename.temp_dir "kido-state" ""
    let id s = Result.get_exn (parse_id s)
    let in_run ~dir i name = Filename.concat (Filename.dirname (task_path ~dir i)) name

    let%expect_test "Create writes meta and task, round-tripping what was written" =
      let dir = temp () in
      let i = id "run-1" in
      create ~dir i "do the thing";
      write_meta ~dir
        {
          id = i;
          name = "kid";
          kind = Agent;
          parent_session = "";
          depth = 1;
          pane = Tmux.Pane.of_string "%1";
          pid = 0;
          cwd = "/tmp";
          model = "";
          tools = [];
          keep_alive = false;
          started_at = Timestamp.now ();
        };
      let got = Option.get_exn_or "ReadMeta" (read_meta ~dir i) in
      Printf.printf "%s %d %s\n" got.name got.depth
        (Option.map_or ~default:"" Tmux.Pane.to_string got.pane);
      print_endline (Option.get_exn_or "ReadTask" (read_task ~dir i));
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
        create ~dir i "x";
        write_meta ~dir
          {
            id = i;
            name;
            kind = k;
            parent_session = "";
            depth = 0;
            pane = Tmux.Pane.of_string "";
            pid = 0;
            cwd = "";
            model = "";
            tools = [];
            keep_alive = false;
            started_at = 0.;
          };
        let got = Option.get_exn_or "ReadMeta" (read_meta ~dir i) in
        Printf.printf "%s %s\n" name (string_of_kind got.kind)
      in
      show "run-bash" Bash;
      show "run-agent" Agent;
      show "run-stream" Stream;
      [%expect {|
    run-bash bash
    run-agent agent
    run-stream stream
    |}]

    let fresh_run name =
      let dir = temp () in
      let i = id name in
      create ~dir i "x";
      (dir, i)

    let%expect_test "Command round-trips exactly, and an empty command is refused" =
      let dir, i = fresh_run "run-cmd" in
      Printf.printf "no command written: %b\n" (Option.is_none (read_command ~dir i));
      let argv = [ "bash"; "-c"; "echo 'it\"s' $HOME `date`\nexit 3" ] in
      write_command ~dir i argv;
      let got = Option.get_exn_or "ReadCommand" (read_command ~dir i) in
      Printf.printf "round-trips: %b\n" (List.equal String.equal got argv);
      write_command ~dir i [];
      Printf.printf "empty command refused: %b\n" (Option.is_none (read_command ~dir i));
      [%expect
        {|
    no command written: true
    round-trips: true
    empty command refused: true
    |}]

    let%expect_test "RecordOutcome writes once; a later write is refused and the first stands" =
      let dir, i = fresh_run "run-3" in
      let wrote_first =
        record_outcome ~dir i { result = Completed; text = ""; at = Some (Timestamp.now ()) }
      in
      let wrote_second =
        record_outcome ~dir i { result = Died; text = ""; at = Some (Timestamp.now ()) }
      in
      let got = Option.get_exn_or "ReadOutcome" (read_outcome ~dir i) in
      Printf.printf "%b %b %s\n" wrote_first wrote_second
        (match got.result with Completed -> "completed" | _ -> "wrong");
      Sys.readdir (Filename.dirname (task_path ~dir i))
      |> Array.to_list |> List.sort String.compare |> List.iter print_endline;
      [%expect {|
    true false completed
    outcome
    task
    |}]

    let%expect_test "RecordOutcome into a run directory that is gone lost the write, not an error" =
      let i = id "run-missing" in
      Printf.printf "%b\n" (record_outcome ~dir:(temp ()) i { result = Died; text = ""; at = None });
      [%expect {| false |}]

    let%expect_test "ResetForResume clears outcome, screen, and (when asked) the delivered marker" =
      let dir, i = fresh_run "run-screen-clear" in
      reset_for_resume ~dir i ~delivered:true;
      Fs.write (in_run ~dir i "screen") "captured";
      ignore (record_outcome ~dir i { result = Died; text = ""; at = None });
      Fs.write (in_run ~dir i "delivered") "";
      reset_for_resume ~dir i ~delivered:true;
      Printf.printf "screen gone: %b\n" (Option.is_none (read_screen ~dir i));
      Printf.printf "outcome gone: %b\n" (Option.is_none (read_outcome ~dir i));
      Printf.printf "delivered gone: %b\n" (not (Sys.file_exists (in_run ~dir i "delivered")));
      [%expect {|
    screen gone: true
    outcome gone: true
    delivered gone: true
    |}]

    let%expect_test "ResetForResume keeps the delivered marker unless asked" =
      let dir, i = fresh_run "run-screen-clear-2" in
      Fs.write (in_run ~dir i "delivered") "";
      reset_for_resume ~dir i ~delivered:false;
      Printf.printf "delivered kept: %b\n" (Sys.file_exists (in_run ~dir i "delivered"));
      [%expect {| delivered kept: true |}]

    let%expect_test "EffectiveOutcome: still running when alive and unrecorded" =
      let dir, i = fresh_run "run-4" in
      Printf.printf "%b\n" (Option.is_none (effective_outcome ~dir i ~pid:(Unix.getpid ())));
      [%expect {| true |}]

    let%expect_test "EffectiveOutcome: Died when dead and unrecorded, never Completed" =
      let dir, i = fresh_run "run-5" in
      let got =
        Option.get_exn_or "EffectiveOutcome" (effective_outcome ~dir i ~pid:(dead_pid ()))
      in
      Printf.printf "%s\n" (match got.result with Died -> "died" | _ -> "wrong");
      [%expect {| died |}]

    let%expect_test "EffectiveOutcome prefers a recorded outcome over a guess" =
      let dir, i = fresh_run "run-6" in
      ignore (record_outcome ~dir i { result = Stopped; text = ""; at = Some (Timestamp.now ()) });
      let got =
        Option.get_exn_or "EffectiveOutcome" (effective_outcome ~dir i ~pid:(dead_pid ()))
      in
      Printf.printf "%s\n" (match got.result with Stopped -> "stopped" | _ -> "wrong");
      [%expect {| stopped |}]

    let%expect_test "List returns the run directories under dir" =
      let dir = temp () in
      create ~dir (id "a") "x";
      create ~dir (id "b") "x";
      Printf.printf "%d\n" (List.length (list ~dir));
      [%expect {| 2 |}]

    let%expect_test "ReadMeta: missing, truncated, or malformed JSON each read as None, not a crash"
        =
      let dir, i = fresh_run "run-bad" in
      Printf.printf "no meta written: %b\n" (Option.is_none (read_meta ~dir i));
      Fs.write (meta_path ~dir i) {|{"id":"run-bad","name":|};
      Printf.printf "truncated: %b\n" (Option.is_none (read_meta ~dir i));
      Fs.write (meta_path ~dir i) {|["not", "an", "object"]|};
      Printf.printf "array: %b\n" (Option.is_none (read_meta ~dir i));
      [%expect {|
    no meta written: true
    truncated: true
    array: true
    |}]

    let%expect_test "ParseID refuses path traversal" =
      List.iter
        (fun s -> Printf.printf "%-10S %b\n" s (Result.is_error (parse_id s)))
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
      Printf.printf "short unchanged: %b\n" (String.equal short (truncate_screen short));
      let long = String.repeat "x" 10 ^ String.repeat "y" (64 * 1024) in
      let truncated = truncate_screen long in
      Printf.printf "%d %b\n" (String.length truncated)
        (String.equal (String.repeat "y" (64 * 1024)) truncated);
      [%expect {|
    short unchanged: true
    65536 true
    |}]
  end)
