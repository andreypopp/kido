type id = string [@@deriving equal, compare, yojson_of]

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

let new_id () =
  Digest.to_hex (In_channel.with_open_bin "/dev/urandom" (fun ic -> really_input_string ic 16))

let string_of_id (id : id) = id
let runs dir = Filename.concat dir "runs"
let dir_for ~dir id = Filename.concat (runs dir) id
let command_path ~dir id = Filename.concat (dir_for ~dir id) "command"
let output_path ~dir id = Filename.concat (dir_for ~dir id) "output"
let meta_path ~dir id = Filename.concat (dir_for ~dir id) "meta.json"
let outcome_path ~dir id = Filename.concat (dir_for ~dir id) "outcome"
let screen_path ~dir id = Filename.concat (dir_for ~dir id) "screen"

type optional_id = Tmux.pane_id option

let yojson_of_optional_id = function None -> `String "" | Some id -> Tmux.yojson_of_pane_id id

let optional_id_of_yojson = function
  | `String "" -> None
  | json -> Some (Tmux.pane_id_of_yojson json)

type parent = Run of id | Pane of Tmux.pane_id [@@deriving equal]

let string_of_parent = function
  | Run id -> string_of_id id
  | Pane pane -> Tmux.string_of_pane_id pane

let yojson_of_parent parent = `String (string_of_parent parent)

let parse_parent s =
  if String.prefix ~pre:"%" s then
    match Tmux.pane_id_of_string s with
    | pane -> Ok (Pane pane)
    | exception Invalid_argument _ -> Error (Printf.sprintf "invalid pane id %S" s)
  else Result.map (fun id -> Run id) (parse_id s)

let parent_of_yojson = function
  | `String s -> (
      match parse_parent s with
      | Ok parent -> parent
      | Error e -> Ppx_yojson_conv_lib.Yojson_conv.of_yojson_error e (`String s))
  | json -> Ppx_yojson_conv_lib.Yojson_conv.of_yojson_error "parent" json

type meta = {
  id : id;
  name : string;
  parent : parent option; [@default None] [@yojson_drop_if Option.is_none]
  pane : optional_id;
  pid : int;
  cwd : string;
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

type command = string list [@@deriving yojson_of]

let write_command ~dir id argv =
  Fs.write ~perm:0o600 (command_path ~dir id) (Yojson.Safe.to_string (yojson_of_command argv))

let write_meta ~dir m =
  Fs.mkdir_p ~perm:0o700 (dir_for ~dir m.id);
  Fs.write_atomic (meta_path ~dir m.id) (Yojson.Safe.to_string (yojson_of_meta m))

let read_meta ~dir id = Fs.read_json (meta_path ~dir id) meta_of_yojson

let record_outcome ~dir id o =
  match
    Fs.write_temp (outcome_path ~dir id) (Yojson.Safe.to_string (yojson_of_outcome o)) Unix.link
  with
  | () -> true
  | exception Unix.Unix_error _ -> false

let read_screen ~dir id = Fs.read (screen_path ~dir id)
let read_outcome ~dir id = Fs.read_json (outcome_path ~dir id) outcome_of_yojson

type pane_state = Live | Dead of { status : int option; signal : string option }

let ended_by_pane = function
  | None -> Some { result = Died; text = ""; at = None }
  | Some Live -> None
  | Some (Dead { status = Some 0; _ }) -> Some { result = Completed; text = ""; at = None }
  | Some (Dead { status = Some n; _ }) ->
      Some { result = Failed; text = Printf.sprintf "exit %d" n; at = None }
  | Some (Dead { signal = Some s; _ }) -> Some { result = Failed; text = "signal " ^ s; at = None }
  | Some (Dead { status = None; signal = None }) -> Some { result = Died; text = ""; at = None }

let effective_outcome ~dir ~pane m =
  match read_outcome ~dir m.id with Some _ as o -> o | None -> ended_by_pane pane

let list ~dir =
  let runs = runs dir in
  match Sys.readdir runs with
  | exception Sys_error _ -> []
  | names ->
      Array.sort String.compare names;
      Array.to_list names
      |> List.filter_map (fun name ->
          Result.to_opt (parse_id name)
          |> Option.filter (fun _ -> Sys.is_directory (Filename.concat runs name)))

let max_screen_bytes = 64 * 1024

let truncate_screen data =
  if String.length data <= max_screen_bytes then data
  else String.drop (String.length data - max_screen_bytes) data

let save_screen tmux ~dir id pane =
  let open Option.Infix in
  let* pane = pane in
  let+ text =
    Result.to_opt
      (Tmux.exec tmux [ "capture-pane"; "-p"; "-t"; Tmux.string_of_pane_id pane; "-S"; "-1000" ])
  in
  let data = truncate_screen text in
  (if not (String.is_empty data) then
     try Fs.write_atomic (screen_path ~dir id) data with Unix.Unix_error _ | Sys_error _ -> ());
  data

type run_outcome_error = No_run of string | Lost of string

let run_outcome ~dir ~result ~text id =
  match read_meta ~dir id with
  | None -> Error (No_run (Printf.sprintf "run %s: no such run" (string_of_id id)))
  | Some m ->
      (match result with Failed -> ignore (save_screen (Tmux.create ()) ~dir id m.pane) | _ -> ());
      let outcome : outcome = { result; text; at = Some (Timestamp.now ()) } in
      if record_outcome ~dir id outcome then Ok ()
      else
        Error (Lost (Printf.sprintf "run %s already has an outcome, or is gone" (string_of_id id)))

let%test_module "Tests" =
  (module struct
    let%expect_test "optional pane ids use an empty string for none" =
      List.iter
        (fun json ->
          match optional_id_of_yojson json with
          | id -> print_endline (Yojson.Safe.to_string (yojson_of_optional_id id))
          | exception Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error (Failure e, _) ->
              print_endline e)
        [ `String ""; `String "%0"; `String "%123"; `String "%"; `String "@1"; `Null ];
      [%expect {|
    ""
    "%0"
    "%123"
    pane
    pane
    pane
    |}]

    let temp () = Filename.temp_dir "kido-state" ""
    let id s = Result.get_exn (parse_id s)

    let meta ?(parent = None) i =
      { id = i; name = ""; parent; pane = None; pid = 0; cwd = ""; started_at = 0. }

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

    let in_run ~dir i name = Filename.concat (Filename.dirname (meta_path ~dir i)) name

    let%expect_test "WriteMeta creates the run directory and round-trips what was written" =
      let dir = temp () in
      let i = id "run-1" in
      write_meta ~dir
        {
          id = i;
          name = "kid";
          parent = None;
          pane = Some (Tmux.pane_id_of_string "%1");
          pid = 0;
          cwd = "/tmp";
          started_at = Timestamp.now ();
        };
      let got = Option.get_exn_or "ReadMeta" (read_meta ~dir i) in
      Printf.printf "%s %s\n" got.name
        (match got.pane with Some x -> Tmux.string_of_pane_id x | None -> "");
      Printf.printf "run dir exists: %b\n" (Sys.file_exists (Filename.concat dir "runs/run-1"));
      [%expect {|
    kid %1
    run dir exists: true
    |}]

    let%expect_test "an outcome with an explicit null time reads as none" =
      let dir = temp () in
      let i = id "run-null" in
      write_meta ~dir (meta i);
      Fs.write (in_run ~dir i "outcome") {|{"result":"completed","at":null}|};
      Printf.printf "%b\n" (Option.exists (fun o -> Option.is_none o.at) (read_outcome ~dir i));
      [%expect {| true |}]

    let fresh_run name =
      let dir = temp () in
      let i = id name in
      Fs.mkdir_p ~perm:0o700 (Filename.dirname (meta_path ~dir i));
      (dir, i)

    let%expect_test "WriteCommand writes the argv as JSON" =
      let dir, i = fresh_run "run-cmd" in
      let argv = [ "bash"; "-c"; "echo 'it\"s' $HOME `date`\nexit 3" ] in
      write_command ~dir i argv;
      Fs.read (command_path ~dir i)
      |> Option.iter (fun json ->
          Printf.printf "round-trips: %b\n"
            (List.equal String.equal
               (Yojson.Safe.from_string json |> [%of_yojson: string list])
               argv));
      [%expect {| round-trips: true |}]

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
      Sys.readdir (Filename.dirname (meta_path ~dir i))
      |> Array.to_list |> List.sort String.compare |> List.iter print_endline;
      [%expect {|
    true false completed
    outcome
    |}]

    let%expect_test "RecordOutcome into a run directory that is gone lost the write, not an error" =
      let i = id "run-missing" in
      Printf.printf "%b\n" (record_outcome ~dir:(temp ()) i { result = Died; text = ""; at = None });
      [%expect {| false |}]

    let%expect_test "effective_outcome: an outcome wins, else the pane decides" =
      let dir = temp () in
      let show name ?outcome pane () =
        let i = id name in
        let m = meta i in
        write_meta ~dir m;
        Option.iter
          (fun result -> ignore (record_outcome ~dir i { result; text = ""; at = None }))
          outcome;
        Printf.printf "%s %s %S\n" name
          (match effective_outcome ~dir ~pane m with
          | Some o -> string_of_result o.result
          | None -> "running")
          (match effective_outcome ~dir ~pane m with Some o -> o.text | None -> "")
      in
      show "running" (Some Live) ();
      show "gone" None ();
      show "exited" (Some (Dead { status = Some 0; signal = None })) ();
      show "exit3" (Some (Dead { status = Some 3; signal = None })) ();
      show "termed" (Some (Dead { status = None; signal = Some "TERM" })) ();
      show "dead-no-status" (Some (Dead { status = None; signal = None })) ();
      show "stopped" ~outcome:Stopped (Some (Dead { status = Some 3; signal = None })) ();
      [%expect
        {|
        running running ""
        gone died ""
        exited completed ""
        exit3 failed "exit 3"
        termed failed "signal TERM"
        dead-no-status died ""
        stopped stopped ""
        |}]

    let%expect_test "List returns the run directories under dir" =
      let dir = temp () in
      write_meta ~dir (meta (id "a"));
      write_meta ~dir (meta (id "b"));
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

    let show_outcome ~dir id =
      match read_outcome ~dir id with
      | None -> print_endline "no outcome"
      | Some o -> Printf.printf "outcome %s %S\n" (string_of_result o.result) o.text

    let record_outcome ~dir result r =
      match
        Result.flat_map
          (run_outcome ~dir ~result ~text:"")
          (Result.map_err (fun m -> Lost m) (parse_id r))
      with
      | Ok () -> ()
      | Error (No_run m) -> Printf.printf "missing: %s\n" m
      | Error (Lost m) -> Printf.printf "refused: %s\n" m

    let%expect_test "run-outcome records one outcome, and only for a valid run id" =
      let dir = temp () in
      let x = id "run-x" in
      write_meta ~dir (meta x);
      show_outcome ~dir x;
      record_outcome ~dir Completed "run-x";
      show_outcome ~dir x;
      record_outcome ~dir Completed "run-x";
      record_outcome ~dir Completed "../escape";
      [%expect
        {|
    no outcome
    outcome completed ""
    refused: run run-x already has an outcome, or is gone
    refused: invalid run id "../escape"
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
