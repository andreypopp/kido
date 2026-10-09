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

type hook = {
  status : status;
  ended : Timestamp.t option;
  background : bool;
  tool_pending : bool; [@key "toolPending"]
}
[@@deriving yojson]

type reporting = Hook of hook | Terminal [@@deriving yojson]

type session = {
  agent : agent;
  name : string;
  pane : Tmux.Pane.id option;
      [@to_yojson Tmux.Pane.optional_id_to_yojson] [@of_yojson Tmux.Pane.optional_id_of_yojson]
  pid : int;
  reporting : reporting;
  ts : Timestamp.t;
  inbox : string; [@default ""]
  activity : string; [@default ""]
  parent : parent option; [@default None]
  depth : int; [@default 0]
  model : string; [@default ""]
}
[@@deriving yojson]

let agent_title title =
  match String.chop_prefix ~pre:"π - " title with
  | Some t -> t
  | None ->
      let rec skip i =
        if i >= String.length title then i
        else
          let d = String.get_utf_8_uchar title i in
          let c = Uchar.to_int (Uchar.utf_decode_uchar d) in
          if
            (c < 0x80 && not (Char.Ascii.is_alphanum (Char.chr c)))
            || (c >= 0x80 && c <= 0xBF)
            || c = 0xD7 || c = 0xF7
            || (c >= 0x2000 && c <= 0x2BFF)
            || (c >= 0x2E00 && c <= 0x2E7F)
            || (c >= 0x3000 && c <= 0x303F)
            || (c >= 0xFE00 && c <= 0xFE0F)
            || c = 0xFFFD
            || (c >= 0x1F000 && c <= 0x1FAFF)
          then skip (i + Uchar.utf_decode_length d)
          else i
      in
      let i = skip 0 in
      String.sub title i (String.length title - i)

let display_name panes (s : session) =
  match s.agent with
  | Pi when not (String.is_empty s.name) -> s.name
  | _ ->
      Option.map_or ~default:""
        (fun (p : Tmux.Pane.t) -> agent_title p.title)
        (Option.flat_map (Tmux.Pane.find panes) s.pane)

let addressable_name (s : session) =
  match s.agent with Pi -> not (String.is_empty s.name) | _ -> true

let dir () =
  let socket =
    Sys.getenv_opt "TMUX"
    |> Option.map (fun s -> List.hd (String.split_on_char ',' s))
    |> Option.filter (fun s ->
        String.equal (Filename.basename s) "socket"
        && Sys.file_exists (Filename.concat (Filename.dirname s) "server.conf"))
  in
  match socket with
  | Some socket -> Filename.dirname socket
  | None -> (
      match (Sys.getenv_opt "KIDO_STATE_DIR", Sys.getenv_opt "XDG_STATE_HOME") with
      | Some d, _ when not (String.is_empty d) -> d
      | _, Some x when not (String.is_empty x) -> Filename.concat x "kido"
      | _ -> Filename.concat (Sys.getenv "HOME") ".local/state/kido")

let sun_path_size =
  if Sys.file_exists "/System/Library/CoreServices/SystemVersion.plist" then 104 else 108

let check_dir ~dir =
  match Unix.lstat dir with
  | st
    when Stdlib.(st.st_kind <> Unix.S_DIR)
         || st.st_uid <> Unix.getuid ()
         || st.st_perm land 0o077 <> 0 ->
      Error
        (Printf.sprintf
           "unsafe server directory %S: must be a directory owned by the user and inaccessible to \
            group and others (mode 0700)"
           dir)
  | _ -> Ok ()
  | exception Unix.Unix_error (ENOENT, _, _) -> Ok ()

let server_socket ~create ~dir =
  let socket = Filename.concat dir "socket" in
  if String.contains dir ',' then
    Error (Printf.sprintf "server directory %S must not contain a comma" dir)
  else if String.length socket >= sun_path_size then
    Error
      (Printf.sprintf "server socket path %S is too long (maximum %d bytes)" socket
         (sun_path_size - 1))
  else begin
    if create then Fs.mkdir_p ~perm:0o700 dir;
    Result.map (fun () -> socket) (check_dir ~dir)
  end

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
let get_live ~dir id = Option.filter (fun s -> alive s.pid) (get ~dir id)

let read_all ~dir =
  match if Sys.file_exists dir then Sys.readdir dir else [||] with
  | names ->
      Array.to_list names
      |> List.filter_map (fun name ->
          let full = Filename.concat dir name in
          match Filename.chop_suffix_opt ~suffix:".json" name with
          | Some id when not (Sys.is_directory full) -> (
              match Option.flat_map parse (Fs.read full) with Some s -> Some (id, s) | _ -> None)
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
      Option.map_or ~default:m
        (fun pane ->
          Tmux.Pane.Map.update pane
            (function Some (_, prev) as kept when not (beats s prev) -> kept | _ -> Some e)
            m)
        s.pane)
    Tmux.Pane.Map.empty sessions

let is_agent_pane states ~pi (p : Tmux.Pane.t) =
  Tmux.Pane.Map.mem p.pane_id states
  || String.equal p.current_command "claude"
  || Procs.Int_set.mem p.pane_pid pi

let held ~dir id pid =
  match get ~dir id with
  | Some prev when prev.pid <> pid && alive prev.pid -> Error prev
  | _ -> Ok ()

let record ~dir id s =
  Fs.mkdir_p ~perm:0o700 dir;
  let path = path ~dir id in
  let tmp = Printf.sprintf "%s.tmp.%d" path (Unix.getpid ()) in
  Fs.write tmp (Yojson.Safe.to_string (session_to_yojson s));
  Fun.protect ~finally:(fun () -> Fs.remove tmp) @@ fun () ->
  match Unix.link tmp path with
  | () -> Ok ()
  | exception Unix.Unix_error (EEXIST, _, _) ->
      Result.flat_map
        (fun () ->
          Unix.rename tmp path;
          held ~dir id s.pid)
        (held ~dir id s.pid)

let remove ~dir id ~pid = Result.map (fun () -> Fs.remove (path ~dir id)) (held ~dir id pid)

let held_message id s =
  Printf.sprintf "session %s is already open in pane %s (pid %d); this process is not tracked" id
    (Option.map_or ~default:"" Tmux.Pane.to_string s.pane)
    s.pid

let stall_threshold () = Timestamp.ms_env Sys.getenv_opt "KIDO_STALL_THRESHOLD_MS" 180.

let stalled_since ~programs ~threshold ~wake ~now s =
  let working =
    match s.reporting with
    | Hook h -> (
        match h.status with Running -> not (h.background || h.tool_pending) | _ -> false)
    | Terminal ->
        Option.exists
          (fun (r : Tmux.Program_status.record) ->
            match r.state with Working _ -> true | _ -> false)
          (Option.flat_map
             (fun pane ->
               Option.flat_map Tmux.Program_status.root (Tmux.Pane.Map.find_opt pane programs))
             s.pane)
  in
  working && Float.(now - max s.ts (Option.value wake ~default:neg_infinity) >= threshold)

let wake_file ~dir = Filename.concat dir "wake"
let wake ~dir = Option.flat_map Timestamp.of_string (Fs.read (wake_file ~dir))

let record_pause ~dir at =
  if not (Option.exists (fun prev -> Float.(at <= prev)) (wake ~dir)) then begin
    Fs.mkdir_p ~perm:0o700 dir;
    Fs.write_atomic (wake_file ~dir) (Timestamp.to_string at)
  end
