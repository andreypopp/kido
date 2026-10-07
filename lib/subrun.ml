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
