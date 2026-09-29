type status = Running | Waiting | Compacting | Idle
type agent = Claude | Pi | Other of string

let string_of_status = function
  | Running -> "running"
  | Waiting -> "waiting"
  | Compacting -> "compacting"
  | Idle -> "idle"

let statuses = List.map (fun s -> (string_of_status s, s)) [ Running; Waiting; Compacting; Idle ]
let status_to_yojson s = `String (string_of_status s)

let status_of_yojson = function
  | `String s ->
      Option.to_result ("unknown status " ^ s) (List.assoc_opt ~eq:String.equal s statuses)
  | _ -> Error "status"

let agent_of_string = function "claude" -> Claude | "pi" -> Pi | s -> Other s
let string_of_agent = function Claude -> "claude" | Pi -> "pi" | Other s -> s
let agent_to_yojson a = `String (string_of_agent a)
let agent_of_yojson = function `String s -> Ok (agent_of_string s) | _ -> Error "agent"

type parent = { session : string; pid : int [@default 0] } [@@deriving yojson]

type session = {
  agent : agent;
  pane : string;
  pid : int;
  status : status;
  ts : Timestamp.t;
  title : string; [@default ""]
  inbox : string; [@default ""]
  ended : Timestamp.t option; [@default None]
  background : bool; [@default false]
  tool_pending : bool; [@key "toolPending"] [@default false]
  activity : string; [@default ""]
  parent : parent option; [@default None]
  depth : int; [@default 0]
  model : string; [@default ""]
}
[@@deriving yojson { strict = false }]

module Panes = Map.Make (String)

let dir () =
  match (Sys.getenv_opt "KIDO_STATE_DIR", Sys.getenv_opt "XDG_STATE_HOME") with
  | Some d, _ when not (String.is_empty d) -> d
  | _, Some x when not (String.is_empty x) -> Filename.concat x "kido"
  | _ -> Filename.concat (Sys.getenv "HOME") ".local/state/kido"

let path ~dir id = Filename.concat dir (id ^ ".json")

let alive pid =
  pid > 0
  &&
  match Unix.kill pid 0 with
  | () -> true
  | exception Unix.Unix_error (EPERM, _, _) -> true
  | exception Unix.Unix_error _ -> false

let parse b =
  match Yojson.Safe.from_string b with
  | j -> Result.to_opt (session_of_yojson j)
  | exception Yojson.Json_error _ -> None

let get ~dir id = Option.flat_map parse (Fs.read (path ~dir id))

let read_all ~dir =
  match Sys.readdir dir with
  | exception Sys_error _ -> []
  | names ->
      Array.to_list names
      |> List.filter_map (fun name ->
          let full = Filename.concat dir name in
          match Filename.chop_suffix_opt ~suffix:".json" name with
          | Some id when not (Sys.is_directory full) -> (
              match Option.flat_map parse (Fs.read full) with
              | Some s when not (String.is_empty s.pane) -> Some (id, s)
              | _ -> None)
          | _ -> None)

let load_live ~dir =
  List.filter
    (fun (id, s) ->
      alive s.pid
      || begin
        Fs.remove (path ~dir id);
        false
      end)
    (read_all ~dir)

let by_pane sessions =
  let outer s = match s.agent with Claude -> false | Pi | Other _ -> true in
  let beats s prev =
    if Bool.equal (outer s) (outer prev) then Float.(s.ts > prev.ts) else outer s
  in
  List.fold_left
    (fun m ((_, s) as e) ->
      Panes.update s.pane
        (function Some (_, prev) as kept when not (beats s prev) -> kept | _ -> Some e)
        m)
    Panes.empty sessions

let is_agent_pane states ~pi (p : Tmux.Pane.t) =
  Panes.mem p.pane_id states
  || String.equal p.current_command "claude"
  || Procs.Int_set.mem p.pane_pid pi

let held ~dir id pid =
  match get ~dir id with
  | Some prev when prev.pid <> pid && alive prev.pid -> Error prev
  | _ -> Ok ()

let record ~dir id s =
  Fs.mkdir_p dir;
  let path = path ~dir id in
  let tmp = Printf.sprintf "%s.tmp.%d" path (Unix.getpid ()) in
  Fs.write tmp (Yojson.Safe.to_string (session_to_yojson s));
  Fun.protect ~finally:(fun () -> Fs.remove tmp) @@ fun () ->
  match Unix.link tmp path with
  | () -> Ok ()
  | exception Unix.Unix_error (EEXIST, _, _) -> (
      match get ~dir id with
      | Some prev when prev.pid <> s.pid && alive prev.pid -> Error prev
      | prev ->
          Unix.rename tmp path;
          if Option.exists (fun p -> p.pid <> s.pid) prev then held ~dir id s.pid else Ok ())

let remove ~dir id ~pid = Result.map (fun () -> Fs.remove (path ~dir id)) (held ~dir id pid)

let held_message id s =
  Printf.sprintf "session %s is already open in pane %s (pid %d); this process is not tracked" id
    s.pane s.pid

let stall_threshold () = Cli.ms_env Sys.getenv_opt "KIDO_STALL_THRESHOLD_MS" 180.

let stalled_since ~threshold ~wake ~now s =
  match s.status with
  | Running when not (s.background || s.tool_pending) ->
      Float.(now - max s.ts (Option.value wake ~default:neg_infinity) >= threshold)
  | Running | Waiting | Compacting | Idle -> false

type marker = { at : Timestamp.t } [@@deriving yojson]

let wake_file ~dir = Filename.concat dir "wake"

let wake ~dir =
  Fs.read (wake_file ~dir)
  |> Option.flat_map (fun b ->
      try Result.to_opt (marker_of_yojson (Yojson.Safe.from_string b))
      with Yojson.Json_error _ -> None)
  |> Option.map (fun m -> m.at)

let record_pause ~dir at =
  if not (Option.exists (fun prev -> Float.(at <= prev)) (wake ~dir)) then begin
    Fs.mkdir_p dir;
    let tmp = wake_file ~dir ^ ".tmp" in
    Fs.write tmp (Yojson.Safe.to_string (marker_to_yojson { at }));
    Unix.rename tmp (wake_file ~dir)
  end

type reading = { wall : Timestamp.t; mono : Mtime.t }

let read_clock () = { wall = Timestamp.now (); mono = Mtime_clock.now () }

let detect_pause prev now =
  let mono = Mtime.Span.to_float_ns (Mtime.span prev.mono now.mono) /. 1e9 in
  Float.(now.wall - prev.wall - mono > 5.)

let symbol u =
  let c = Uchar.to_int u in
  (c < 0x80 && not (Char.Ascii.is_alphanum (Char.chr c)))
  || (c >= 0x80 && c <= 0xBF)
  || c = 0xD7 || c = 0xF7
  || (c >= 0x2000 && c <= 0x2BFF)
  || (c >= 0x2E00 && c <= 0x2E7F)
  || (c >= 0x3000 && c <= 0x303F)
  || (c >= 0xFE00 && c <= 0xFE0F)
  || c = 0xFFFD
  || (c >= 0x1F000 && c <= 0x1FAFF)

let agent_title title =
  match String.chop_prefix ~pre:"π - " title with
  | Some t -> t
  | None ->
      let rec skip i =
        if i >= String.length title then i
        else
          let d = String.get_utf_8_uchar title i in
          if symbol (Uchar.utf_decode_uchar d) then skip (i + Uchar.utf_decode_length d) else i
      in
      let i = skip 0 in
      String.sub title i (String.length title - i)
