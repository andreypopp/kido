type id = string [@@deriving equal, yojson_of]

let parse_id s =
  if
    String.is_empty s || String.mem ~sub:"/" s || String.mem ~sub:"\\" s || String.prefix ~pre:"." s
  then Error (Printf.sprintf "invalid run id %S" s)
  else Ok s

let id_of_yojson json =
  let reject = Ppx_yojson_conv_lib.Yojson_conv.of_yojson_error in
  match json with
  | `String s -> ( match parse_id s with Ok id -> id | Error e -> reject e json)
  | _ -> reject "invalid run id" json

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
let pi_path ~dir id = Filename.concat (dir_for ~dir id) "pi.json"

type kind = Pi | Agent | Bash | Stream

let string_of_kind = function Pi -> "pi" | Agent -> "agent" | Bash -> "bash" | Stream -> "stream"
let kinds = List.map (fun k -> (string_of_kind k, k)) [ Pi; Agent; Bash; Stream ]
let yojson_of_kind k = `String (string_of_kind k)

let kind_of_yojson json =
  match json with
  | `String s when List.mem_assoc ~eq:String.equal s kinds -> List.assoc ~eq:String.equal s kinds
  | _ -> Ppx_yojson_conv_lib.Yojson_conv.of_yojson_error "kind" json

type meta = {
  id : id;
  name : string;
  kind : kind;
  parent : id option; [@default None] [@yojson_drop_if Option.is_none]
  pane : Tmux_pane.optional_id;
  pid : int;
  cwd : string;
  model : string; [@default ""] [@yojson_drop_default.equal]
  tools : string list; [@default []] [@yojson_drop_default.equal]
  keep_alive : bool; [@key "keepAlive"] [@default false] [@yojson_drop_default.equal]
  started_at : Timestamp.t; [@key "startedAt"]
}
[@@deriving yojson]

let label m = if String.is_empty m.name then string_of_id m.id else m.name

type pi = {
  pid : int;
  pane : Tmux_pane.optional_id;
  ts : Timestamp.t;
  inbox : string; [@default ""] [@yojson_drop_default.equal]
  activity : string; [@default ""] [@yojson_drop_default.equal]
  model : string; [@default ""] [@yojson_drop_default.equal]
  name : string; [@default ""] [@yojson_drop_default.equal]
  session_file : string; [@key "sessionFile"] [@default ""] [@yojson_drop_default.equal]
}
[@@deriving yojson]

let alive pid =
  pid > 0
  &&
  match Unix.kill pid 0 with
  | () -> true
  | exception Unix.Unix_error (EPERM, _, _) -> true
  | exception Unix.Unix_error _ -> false

let read_pi ~dir id = Fs.read_json (pi_path ~dir id) pi_of_yojson

let live_pi ~dir id =
  Result.to_opt (parse_id id)
  |> Option.flat_map (read_pi ~dir)
  |> Option.filter (fun p -> alive p.pid)

let live_parent ~dir id =
  Option.to_result
    (Printf.sprintf "no live process holds session %S; the parent is gone, nothing sent" id)
    (live_pi ~dir id)

let caller ~dir s =
  Result.to_opt (parse_id s)
  |> Option.flat_map (fun id -> Option.map (Pair.make id) (read_pi ~dir id))

let held ~dir id pid =
  match read_pi ~dir id with
  | Some prev when prev.pid <> pid && alive prev.pid -> Error prev
  | _ -> Ok ()

let write_pi ~dir id ~holder p =
  Fs.mkdir_p ~perm:0o700 (dir_for ~dir id);
  let write = Fs.write_temp (pi_path ~dir id) (Yojson.Safe.to_string (yojson_of_pi p)) in
  match write Unix.link with
  | () -> Ok ()
  | exception Unix.Unix_error (EEXIST, _, _) ->
      Result.flat_map
        (fun () ->
          write Unix.rename;
          held ~dir id holder)
        (held ~dir id holder)

let release ~dir id ~holder =
  match read_pi ~dir id with None -> Ok () | Some p -> write_pi ~dir id ~holder { p with pid = 0 }

type result = Completed | Failed | Died | Stopped

let string_of_result = function
  | Completed -> "completed"
  | Failed -> "failed"
  | Died -> "died"
  | Stopped -> "stopped"

let results = List.map (fun r -> (string_of_result r, r)) [ Completed; Failed; Died; Stopped ]
let yojson_of_result r = `String (string_of_result r)

let result_of_yojson json =
  match json with
  | `String s when List.mem_assoc ~eq:String.equal s results ->
      List.assoc ~eq:String.equal s results
  | _ -> Ppx_yojson_conv_lib.Yojson_conv.of_yojson_error "result" json

type outcome = {
  result : result;
  text : string; [@default ""] [@yojson_drop_default.equal]
  at : Timestamp.t option; [@default None] [@yojson_drop_if Option.is_none]
}
[@@deriving yojson] [@@yojson.allow_extra_fields]

let create ~dir id task =
  Fs.mkdir_p ~perm:0o700 (dir_for ~dir id);
  Fs.write ~perm:0o600 (task_path ~dir id) task

type command = string list [@@deriving yojson]

let write_command ~dir id argv =
  Fs.write ~perm:0o600 (command_path ~dir id) (Yojson.Safe.to_string (yojson_of_command argv))

let read_command ~dir id =
  match Fs.read_json (command_path ~dir id) command_of_yojson with Some [] | None -> None | c -> c

let write_meta ~dir m =
  Fs.mkdir_p ~perm:0o700 (dir_for ~dir m.id);
  Fs.write_atomic (meta_path ~dir m.id) (Yojson.Safe.to_string (yojson_of_meta m))

let create_meta ~dir m =
  Fs.mkdir_p ~perm:0o700 (dir_for ~dir m.id);
  try Fs.write_temp (meta_path ~dir m.id) (Yojson.Safe.to_string (yojson_of_meta m)) Unix.link
  with Unix.Unix_error (EEXIST, _, _) -> ()

let read_meta ~dir id = Fs.read_json (meta_path ~dir id) meta_of_yojson
let find ~dir s = Option.flat_map (read_meta ~dir) (Result.to_opt (parse_id s))

type t = { meta : meta; pi : pi option }

let load ~dir s = Option.map (fun meta -> { meta; pi = read_pi ~dir meta.id }) (find ~dir s)
let holder r = Option.filter (fun p -> alive p.pid) r.pi

let name { meta; pi } =
  match pi with Some { name; _ } when not (String.is_empty name) -> name | _ -> meta.name

let display_name panes (s : pi) =
  if not (String.is_empty s.name) then s.name
  else
    Option.map_or ~default:""
      (fun (p : Tmux_pane.t) -> p.title)
      (Option.flat_map (Tmux_pane.find panes) s.pane)

let ancestors ~dir m =
  let rec up seen m =
    match m.parent with
    | Some p when not (List.mem ~eq:equal_id p seen) ->
        p :: Option.map_or ~default:[] (up (p :: seen)) (read_meta ~dir p)
    | _ -> []
  in
  up [ m.id ] m

let depth ~dir m = List.length (ancestors ~dir m)
let write_report ~dir id text = Fs.write_atomic ~perm:0o600 (report_path ~dir id) text
let has_report ~dir id = Sys.file_exists (report_path ~dir id)
let read_task ~dir id = Fs.read (task_path ~dir id)

let record_outcome ~dir id o =
  match read_meta ~dir id with
  | Some { kind = Pi; _ } -> false
  | _ -> (
      match
        Fs.write_temp (outcome_path ~dir id) (Yojson.Safe.to_string (yojson_of_outcome o)) Unix.link
      with
      | () -> true
      | exception Unix.Unix_error _ -> false)

let read_screen ~dir id = Fs.read (screen_path ~dir id)

let reset_for_resume ~dir id ~delivered =
  let paths = [ outcome_path ~dir id; screen_path ~dir id ] in
  let paths = if delivered then paths @ [ delivered_path ~dir id ] else paths in
  List.iter Fs.remove paths

let read_outcome ~dir id = Fs.read_json (outcome_path ~dir id) outcome_of_yojson

let effective_outcome ~dir m =
  let ended result = Some { result; text = ""; at = None } in
  match m.kind with
  | Pi -> (
      match read_pi ~dir m.id with
      | Some { pid; _ } when alive pid -> None
      | Some { pid = 0; _ } -> ended Completed
      | _ -> ended Died)
  | Agent | Bash | Stream -> (
      match read_outcome ~dir m.id with
      | Some _ as o -> o
      | None -> if alive m.pid then None else ended Died)

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

let save_screen tmux ~dir id pane =
  Option.flat_map
    (fun pane ->
      Option.map
        (fun text ->
          let data = truncate_screen text in
          (if not (String.is_empty data) then
             try Fs.write_atomic (screen_path ~dir id) data
             with Unix.Unix_error _ | Sys_error _ -> ());
          data)
        (Result.to_opt
           (Tmux.exec tmux
              [ "capture-pane"; "-p"; "-t"; Tmux.string_of_pane_id pane; "-S"; "-1000" ])))
    pane

let marked ~dir panes =
  List.fold_left
    (fun m (p : Tmux_pane.t) ->
      Option.map_or ~default:m
        (fun r -> Tmux.Pane_map.add p.pane_id r m)
        (Option.flat_map (load ~dir) p.run))
    Tmux.Pane_map.empty panes

let window_pane ~(runs : t Tmux.Pane_map.t) panes window =
  List.find_opt
    (fun (p : Tmux_pane.t) ->
      Tmux.equal_window_id p.window_id window
      && Option.is_some p.run
      &&
      match Tmux.Pane_map.find_opt p.pane_id runs with
      | Some { meta = { kind = Pi; _ }; _ } -> false
      | _ -> true)
    panes

let agents runs =
  Tmux.Pane_map.filter_map
    (fun pane (r : t) ->
      holder r
      |> Option.filter (fun (s : pi) -> Option.equal Tmux.equal_pane_id s.pane (Some pane))
      |> Option.map (fun s -> (string_of_id r.meta.id, s)))
    runs

let%test_module "Tests" =
  (module struct
    open Test_support

    let temp () = Filename.temp_dir "kido-state" ""
    let id s = Result.get_exn (parse_id s)

    let meta ?(kind = Agent) ?(parent = None) i =
      {
        id = i;
        name = "";
        kind;
        parent;
        pane = None;
        pid = 0;
        cwd = "";
        model = "";
        tools = [];
        keep_alive = false;
        started_at = 0.;
      }

    let%expect_test "meta rejects path traversal in id and parent" =
      let json = yojson_of_meta (meta (id "safe")) in
      List.iter
        (fun field ->
          let fields = match json with `Assoc fields -> fields | _ -> assert false in
          let json =
            `Assoc ((field, `String "../x") :: List.remove_assoc ~eq:String.equal field fields)
          in
          let rejected =
            match meta_of_yojson json with
            | _ -> false
            | exception Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error _ -> true
          in
          Printf.printf "%s rejected: %b\n" field rejected)
        [ "id"; "parent" ];
      [%expect {|
        id rejected: true
        parent rejected: true
        |}]

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
          parent = None;
          pane = Some (Tmux.pane_id_of_string "%1");
          pid = 0;
          cwd = "/tmp";
          model = "";
          tools = [];
          keep_alive = false;
          started_at = Timestamp.now ();
        };
      let got = Option.get_exn_or "ReadMeta" (read_meta ~dir i) in
      Printf.printf "%s %s\n" got.name (Option.map_or ~default:"" Tmux.string_of_pane_id got.pane);
      print_endline (Option.get_exn_or "ReadTask" (read_task ~dir i));
      Printf.printf "run dir exists: %b\n" (Sys.file_exists (Filename.concat dir "runs/run-1"));
      [%expect {|
    kid %1
    do the thing
    run dir exists: true
    |}]

    let%expect_test "an outcome with an explicit null time reads as none" =
      let dir = temp () in
      let i = id "run-null" in
      create ~dir i "";
      Fs.write (in_run ~dir i "outcome") {|{"result":"completed","at":null}|};
      Printf.printf "%b\n" (Option.exists (fun o -> Option.is_none o.at) (read_outcome ~dir i));
      [%expect {| true |}]

    let%expect_test "Kind round-trips" =
      let dir = temp () in
      let show name k =
        let i = id name in
        create ~dir i "x";
        write_meta ~dir (meta ~kind:k i);
        let got = Option.get_exn_or "ReadMeta" (read_meta ~dir i) in
        Printf.printf "%s %s\n" name (string_of_kind got.kind)
      in
      show "run-bash" Bash;
      show "run-agent" Agent;
      show "run-stream" Stream;
      show "run-pi" Pi;
      [%expect {|
    run-bash bash
    run-agent agent
    run-stream stream
    run-pi pi
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

    let%expect_test "effective_outcome: recorded, else derived from the process" =
      let dir = temp () in
      let show name kind ?pid ?outcome ?pi () =
        let i = id name in
        let m = { (meta ~kind i) with pid = Option.value pid ~default:0 } in
        write_meta ~dir m;
        Option.iter
          (fun result -> ignore (record_outcome ~dir i { result; text = ""; at = None }))
          outcome;
        Option.iter
          (fun pid ->
            ignore
              (write_pi ~dir i ~holder:pid
                 {
                   pid;
                   pane = None;
                   ts = 0.;
                   inbox = "";
                   activity = "";
                   model = "";
                   name = "";
                   session_file = "";
                 }))
          pi;
        Printf.printf "%s %s\n" name
          (Option.map_or ~default:"running"
             (fun o -> string_of_result o.result)
             (effective_outcome ~dir m))
      in
      show "live" Agent ~pid:(Unix.getpid ()) ();
      show "dead" Agent ~pid:(dead_pid ()) ();
      show "stopped" Agent ~pid:(dead_pid ()) ~outcome:Stopped ();
      show "pi-live" Pi ~pi:(Unix.getpid ()) ();
      show "pi-released" Pi ~pi:0 ();
      show "pi-dead" Pi ~pi:(dead_pid ()) ();
      show "pi-never" Pi ();
      [%expect
        {|
        live running
        dead died
        stopped stopped
        pi-live running
        pi-released completed
        pi-dead died
        pi-never died
        |}]

    let%expect_test "one live holder per run" =
      let dir = temp () in
      let me = Unix.getpid () in
      let pi pid pane =
        {
          pid;
          pane = Some (Tmux.pane_id_of_string pane);
          ts = 0.;
          inbox = "";
          activity = pane;
          model = "";
          name = "";
          session_file = "/s";
        }
      in
      let outcome = function
        | Ok () -> print_endline "ok"
        | Error (h : pi) -> Printf.printf "held by pid %d in %s\n" h.pid h.activity
      in
      let show i =
        Option.iter
          (fun (p : pi) -> Printf.printf "%s pid %d %s\n" p.activity p.pid p.session_file)
          (read_pi ~dir i)
      in
      let s = id "s" and d = id "d" in
      outcome (write_pi ~dir s ~holder:1 (pi 1 "%1"));
      outcome (write_pi ~dir s ~holder:me (pi me "%2"));
      outcome (release ~dir s ~holder:me);
      show s;
      outcome (write_pi ~dir d ~holder:(dead_pid ()) (pi (dead_pid ()) "%1"));
      outcome (write_pi ~dir d ~holder:me (pi me "%2"));
      outcome (release ~dir d ~holder:me);
      show d;
      [%expect
        {|
        ok
        held by pid 1 in %1
        held by pid 1 in %1
        %1 pid 1 /s
        ok
        ok
        ok
        %2 pid 0 /s
        |}]

    let%expect_test "ancestors and depth follow parents, and a cycle ends the walk" =
      let dir = temp () in
      let edge i parent = write_meta ~dir (meta ~parent (id i)) in
      edge "root" None;
      edge "kid" (Some "root");
      edge "loner" None;
      edge "grandkid" (Some "loner");
      edge "a" (Some "b");
      edge "b" (Some "a");
      List.iter
        (fun i ->
          let m = Option.get_exn_or "meta" (read_meta ~dir i) in
          Printf.printf "%s %d [%s]\n" i (depth ~dir m) (String.concat " " (ancestors ~dir m)))
        [ "root"; "kid"; "loner"; "grandkid"; "a" ];
      [%expect
        {|
        root 0 []
        kid 1 [root]
        loner 0 []
        grandkid 1 [loner]
        a 1 [b]
        |}]

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
