type id = string [@@deriving yojson]

let parse_id s =
  if
    String.is_empty s || String.mem ~sub:"/" s || String.mem ~sub:"\\" s || String.prefix ~pre:"." s
  then Error (Printf.sprintf "invalid run id %S" s)
  else Ok s

let new_id () = Msg.new_id ()
let string_of_id (id : id) = id
let dir_for ~dir id = Filename.concat dir id
let task_path ~dir id = Filename.concat (dir_for ~dir id) "task"
let command_path ~dir id = Filename.concat (dir_for ~dir id) "command"
let output_path ~dir id = Filename.concat (dir_for ~dir id) "output"
let report_path ~dir id = Filename.concat (dir_for ~dir id) "report"
let delivered_path ~dir id = Filename.concat (dir_for ~dir id) "delivered"
let meta_path ~dir id = Filename.concat (dir_for ~dir id) "meta.json"
let outcome_path ~dir id = Filename.concat (dir_for ~dir id) "outcome"
let screen_path ~dir id = Filename.concat (dir_for ~dir id) "screen"

type kind = Agent | Bash

let string_of_kind = function Agent -> "agent" | Bash -> "bash"
let kinds = [ ("agent", Agent); ("bash", Bash) ]
let kind_to_yojson k = `String (string_of_kind k)

let kind_of_yojson = function
  | `String s -> Option.to_result ("unknown kind " ^ s) (List.assoc_opt ~eq:String.equal s kinds)
  | _ -> Error "kind"

type meta = {
  id : id;
  name : string;
  kind : kind option; [@default None]
  parent_session : string; [@key "parentSession"] [@default ""]
  depth : int;
  pane : string;
  pid : int;
  cwd : string;
  model : string; [@default ""]
  tools : string list; [@default []]
  keep_alive : bool; [@key "keepAlive"] [@default false]
  started_at : Timestamp.t; [@key "startedAt"]
}
[@@deriving yojson { strict = false }]

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
  Fs.mkdir_p (dir_for ~dir id);
  Fs.write ~perm:0o600 (task_path ~dir id) task

let json_of_argv argv = `List (List.map (fun s -> `String s) argv)

let argv_of_json = function
  | `List items ->
      List.fold_right
        (fun item acc ->
          match (item, acc) with `String s, Some rest -> Some (s :: rest) | _ -> None)
        items (Some [])
  | _ -> None

let write_command ~dir id argv =
  Fs.write ~perm:0o600 (command_path ~dir id) (Yojson.Safe.to_string (json_of_argv argv))

let read_command ~dir id =
  match Fs.read (command_path ~dir id) with
  | None -> None
  | Some raw -> (
      match Yojson.Safe.from_string raw with
      | exception Yojson.Json_error _ -> None
      | json -> ( match argv_of_json json with Some [] | None -> None | Some argv -> Some argv))

(* A same-directory temp file unique per writer (O_EXCL retried on a name
   clash), then rename: two writers of one path never share a temp file. *)
let write_atomic ?(perm = 0o644) path data =
  let rec create_unique () =
    let tmp = Printf.sprintf "%s.tmp.%d.%d" path (Unix.getpid ()) (Random.bits ()) in
    match Unix.openfile tmp [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] perm with
    | fd -> (tmp, fd)
    | exception Unix.Unix_error (Unix.EEXIST, _, _) -> create_unique ()
  in
  let tmp, fd = create_unique () in
  Fun.protect
    ~finally:(fun () -> Fs.remove tmp)
    (fun () ->
      Fun.protect
        ~finally:(fun () -> Unix.close fd)
        (fun () -> ignore (Unix.write_substring fd data 0 (String.length data)));
      Unix.rename tmp path)

let write_meta ~dir m =
  Fs.mkdir_p (dir_for ~dir m.id);
  write_atomic (meta_path ~dir m.id) (Yojson.Safe.to_string (meta_to_yojson m))

let read_meta ~dir id =
  match Fs.read (meta_path ~dir id) with
  | None -> None
  | Some raw -> (
      match Yojson.Safe.from_string raw with
      | exception Yojson.Json_error _ -> None
      | json -> Result.to_opt (meta_of_yojson json))

let write_report ~dir id text = write_atomic ~perm:0o600 (report_path ~dir id) text
let has_report ~dir id = Sys.file_exists (report_path ~dir id)
let read_task ~dir id = Fs.read (task_path ~dir id)

let record_outcome ~dir id o =
  let path = outcome_path ~dir id in
  match Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o644 with
  | fd ->
      let data = Yojson.Safe.to_string (outcome_to_yojson o) in
      Fun.protect
        ~finally:(fun () -> Unix.close fd)
        (fun () -> ignore (Unix.write_substring fd data 0 (String.length data)));
      true
  | exception Unix.Unix_error (Unix.EEXIST, _, _) -> false

let write_screen ~dir id data = write_atomic (screen_path ~dir id) data
let read_screen ~dir id = Fs.read (screen_path ~dir id)

let reset_for_resume ~dir id ~delivered =
  let paths = [ outcome_path ~dir id; screen_path ~dir id ] in
  let paths = if delivered then paths @ [ delivered_path ~dir id ] else paths in
  List.iter Fs.remove paths

let read_outcome ~dir id =
  match Fs.read (outcome_path ~dir id) with
  | None -> None
  | Some raw -> (
      match Yojson.Safe.from_string raw with
      | exception Yojson.Json_error _ -> None
      | json -> Result.to_opt (outcome_of_yojson json))

let effective_outcome ~dir id ~pid =
  match read_outcome ~dir id with
  | Some _ as o -> o
  | None -> if State.alive pid then None else Some { result = Died; text = ""; at = None }

let list ~dir =
  match Sys.readdir dir with
  | exception Sys_error _ -> []
  | names ->
      Array.sort String.compare names;
      Array.to_list names |> List.filter (fun name -> Sys.is_directory (Filename.concat dir name))

let max_screen_bytes = 64 * 1024

let truncate_screen data =
  let n = String.length data in
  if n > max_screen_bytes then String.sub data (n - max_screen_bytes) max_screen_bytes else data
