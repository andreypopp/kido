type status = Running | Waiting | Idle
type agent = Pi | Other of string

let string_of_status = function Running -> "running" | Waiting -> "waiting" | Idle -> "idle"
let agent_of_string = function "pi" -> Pi | s -> Other s
let string_of_agent = function Pi -> "pi" | Other s -> s
let agent_to_yojson a = `String (string_of_agent a)
let agent_of_yojson = function `String s -> Ok (agent_of_string s) | _ -> Error "agent"

type parent = { session : string; pid : int [@default 0] } [@@deriving yojson]

type session = {
  agent : agent;
  name : string;
  pane : Tmux.pane_id option;
      [@to_yojson Tmux_pane.optional_id_to_yojson] [@of_yojson Tmux_pane.optional_id_of_yojson]
  pid : int;
  ts : Timestamp.t;
  inbox : string; [@default ""]
  activity : string; [@default ""]
  parent : parent option; [@default None]
  depth : int; [@default 0]
  model : string; [@default ""]
}
[@@deriving yojson]

let display_name panes (s : session) =
  match s.agent with
  | Pi when not (String.is_empty s.name) -> s.name
  | _ ->
      Option.map_or ~default:""
        (fun (p : Tmux_pane.t) -> p.title)
        (Option.flat_map (Tmux_pane.find panes) s.pane)

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
  List.fold_left
    (fun m ((_, s) as e) ->
      Option.map_or ~default:m
        (fun pane ->
          Tmux.Pane_map.update pane
            (function Some (_, prev) as kept when Float.(s.ts <= prev.ts) -> kept | _ -> Some e)
            m)
        s.pane)
    Tmux.Pane_map.empty sessions

type ssh_kind = Remote_terminal | Remote_agent of { name : string }

type pane_kind =
  | Terminal
  | Some_agent of { name : string }
  | Pi_agent of { id : string; session : session }
  | Ssh of { user : string; host : string; pane : ssh_kind }

let pane_kind ~states (p : Tmux_pane.t) =
  let app =
    Tmux.Program_status.root p.program_status
    |> Option.flat_map (fun (r : Tmux.Program_status.record) -> r.app)
  in
  match (p.ssh, p.current_command, app) with
  | Some (user, host), "ssh", app ->
      let pane =
        match app with
        | Some (("pi" | "claude-code") as name) -> Remote_agent { name }
        | _ -> Remote_terminal
      in
      Ssh { user; host; pane }
  | _, _, Some "pi" -> (
      match Tmux.Pane_map.find_opt p.pane_id states with
      | Some (id, session) -> Pi_agent { id; session }
      | None -> Some_agent { name = "pi" })
  | _, _, Some "claude-code" -> Some_agent { name = "claude-code" }
  | _ -> Terminal

let pane_title (p : Tmux_pane.t) = function
  | Ssh { pane = Remote_terminal; _ } -> None
  | Ssh { pane = Remote_agent { name }; _ } ->
      Some (if String.is_empty p.title then name else p.title)
  | Terminal -> None
  | Pi_agent { session; _ } -> Some (if String.is_empty session.name then p.title else session.name)
  | Some_agent { name } -> Some (if String.is_empty p.title then name else p.title)

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
    (Option.map_or ~default:"" Tmux.pane_id_to_string s.pane)
    s.pid

let stall_threshold () = Timestamp.ms_env Sys.getenv_opt "KIDO_STALL_THRESHOLD_MS" 180.

let stalled_since ~root ~threshold ~wake ~now s =
  let working =
    Option.exists
      (fun (r : Tmux.Program_status.record) ->
        Option.exists (String.equal "pi") r.app
        && match r.state with Working _ -> true | _ -> false)
      root
  in
  working && Float.(now - max s.ts (Option.value wake ~default:neg_infinity) >= threshold)

let wake_file ~dir = Filename.concat dir "wake"
let wake ~dir = Option.flat_map Timestamp.of_string (Fs.read (wake_file ~dir))

let record_pause ~dir at =
  if not (Option.exists (fun prev -> Float.(at <= prev)) (wake ~dir)) then begin
    Fs.mkdir_p ~perm:0o700 dir;
    Fs.write_atomic (wake_file ~dir) (Timestamp.to_string at)
  end

let%test_module "Tests" =
  (module struct
    open Test_support
    open Tmux_pane_fixture

    let session ?(agent = Pi) ?(pane = "%1") ?(pid = Unix.getpid ()) ?(ts = 1_700_000_000.)
        ?(inbox = "") ?parent ?(depth = 0) () : session =
      {
        agent;
        name = "";
        pane = Tmux.pane_id_of_string pane;
        pid;
        ts;
        inbox;
        activity = "";
        parent = Option.map (fun session : parent -> { session; pid = 0 }) parent;
        depth;
        model = "";
      }

    let write ~dir id s =
      Fs.write (Filename.concat dir (id ^ ".json")) (Yojson.Safe.to_string (session_to_yojson s))

    let temp () = Filename.temp_dir "kido-state" ""

    let show_panes live =
      Tmux.Pane_map.iter
        (fun pane (id, _) -> Printf.printf "%s: %s\n" (Tmux.pane_id_to_string pane) id)
        (by_pane live)

    let outcome = function
      | Ok () -> print_endline "ok"
      | Error (h : session) ->
          Printf.printf "held by pid %d in %s\n" h.pid
            (Option.map_or ~default:"" Tmux.pane_id_to_string h.pane)

    let%expect_test "a record is written compactly, without its empty fields" =
      let s = session () ~ts:1_700_000_000.25 in
      print_endline (Yojson.Safe.to_string (session_to_yojson { s with pid = 42 }));
      [%expect {| {"agent":"pi","name":"","pane":"%1","pid":42,"ts":"2023-11-14T22:13:20.25Z"} |}]

    let%expect_test "the latest report wins a shared pane" =
      let dir = temp () in
      write ~dir "a" (session ~pane:"%1" ~ts:100. ());
      write ~dir "b" (session ~pane:"%1" ~ts:200. ());
      write ~dir "pi-root" (session ~agent:Pi ~pane:"%9" ~ts:100. ());
      write ~dir "pi-headless" (session ~agent:(Other "pi2") ~pane:"%9" ~ts:200. ());
      show_panes (load_live ~dir);
      Fs.remove (Filename.concat dir "pi-headless.json");
      show_panes (load_live ~dir);
      [%expect {|
    %1: b
    %9: pi-headless
    %1: b
    %9: pi-root
    |}]

    let%expect_test "load_live deletes a dead agent's record and skips a malformed one" =
      let dir = temp () in
      write ~dir "live" (session () ~pane:"%1");
      write ~dir "dead" (session () ~pane:"%2" ~pid:(dead_pid ()));
      Fs.write (Filename.concat dir "malformed.json") "{not json";
      Unix.mkdir (Filename.concat dir "runs.json") 0o755;
      List.iter (fun (id, _) -> print_endline id) (load_live ~dir);
      List.iter
        (fun f -> Printf.printf "%s %b\n" f (Sys.file_exists (Filename.concat dir f)))
        [ "dead.json"; "malformed.json" ];
      [%expect {|
    live
    dead.json false
    malformed.json true
    |}]

    let%expect_test "get_live reads one session without deleting dead records" =
      let dir = temp () in
      write ~dir "live" (session () ~pane:"%1");
      write ~dir "dead" (session () ~pane:"%2" ~pid:(dead_pid ()));
      Fs.write
        (Filename.concat dir "no-pane.json")
        (Yojson.Safe.to_string
           (`Assoc
              (("pane", `String "")
              :: List.remove_assoc ~eq:String.equal "pane"
                   (Yojson.Safe.Util.to_assoc (session_to_yojson (session ()))))));
      List.iter
        (fun id -> Printf.printf "%s %b\n" id (Option.is_some (get_live ~dir id)))
        [ "live"; "dead"; "no-pane"; "missing" ];
      Printf.printf "dead record kept %b\n" (Option.is_some (get ~dir "dead"));
      [%expect
        {|
    live true
    dead false
    no-pane true
    missing false
    dead record kept true
    |}]

    let%expect_test "one live holder per session id" =
      let dir = temp () in
      let me = Unix.getpid () in
      outcome (record ~dir "s" { (session () ~pane:"%1" ~pid:1) with inbox = "/tmp/h.sock" });
      outcome (record ~dir "s" (session () ~pane:"%2" ~pid:me));
      outcome (remove ~dir "s" ~pid:me);
      Option.iter
        (fun (s : session) ->
          Printf.printf "kept %s %d %s\n"
            (Option.map_or ~default:"" Tmux.pane_id_to_string s.pane)
            s.pid s.inbox)
        (get ~dir "s");
      outcome (record ~dir "d" (session () ~pane:"%1" ~pid:(dead_pid ())));
      outcome (record ~dir "d" (session () ~pane:"%2" ~pid:me));
      Option.iter
        (fun (s : session) ->
          Printf.printf "taken over by %s\n"
            (Option.map_or ~default:"" Tmux.pane_id_to_string s.pane))
        (get ~dir "d");
      outcome (record ~dir "d" (session () ~pane:"%2" ~pid:me));
      outcome (remove ~dir "d" ~pid:me);
      Printf.printf "removed %b\n" (Option.is_none (get ~dir "d"));
      print_endline (held_message "s" (session () ~pane:"%1" ~pid:1));
      [%expect
        {|
    ok
    held by pid 1 in %1
    held by pid 1 in %1
    kept %1 1 /tmp/h.sock
    ok
    ok
    taken over by %2
    ok
    ok
    removed true
    session s is already open in pane %1 (pid 1); this process is not tracked
    |}]

    let%expect_test "the wake marker keeps the latest wake" =
      let dir = temp () in
      let show () = print_endline (Option.map_or ~default:"none" Timestamp.to_string (wake ~dir)) in
      show ();
      record_pause ~dir 1_700_001_000.;
      record_pause ~dir 1_700_000_000.;
      show ();
      [%expect {|
    none
    2023-11-14T22:30:00Z
    |}]

    let%expect_test "only a root app identifies a pane" =
      let p = pane ~cmd:"pi" "%1" in
      let states = by_pane [ ("local", session ()) ] in
      List.iter
        (fun (body, local) ->
          let status = Result.get_exn (Tmux.Program_status.parse body) in
          let p = { p with program_status = status } in
          let states = if local then states else Tmux.Pane_map.empty in
          let kind = pane_kind ~states p in
          print_endline
            (match kind with
            | Terminal -> "terminal"
            | Some_agent { name } -> "native " ^ name
            | Pi_agent { id; _ } -> "local " ^ id
            | Ssh { user; host; _ } -> "ssh " ^ user ^ "@" ^ host))
        [
          ({|{"serial":1,"records":[]}|}, true);
          ({|{"serial":1,"records":[{"id":"child","app":"pi","state":"idle"}]}|}, true);
          ({|{"serial":1,"records":[{"id":"","app":"pi","state":"idle"}]}|}, true);
          ({|{"serial":1,"records":[{"id":"","app":"pi","state":"idle"}]}|}, false);
          ({|{"serial":1,"records":[{"id":"","app":"claude-code","state":"idle"}]}|}, true);
          ({|{"serial":1,"records":[{"id":"","app":"builder","state":"idle"}]}|}, true);
        ];
      [%expect
        {|
    terminal
    terminal
    local local
    native pi
    native claude-code
    terminal
    |}]

    let%expect_test "a missing state dir holds no records; an unreadable one is an error" =
      let dir = Filename.concat (Filename.temp_dir "kido-state" "") "absent" in
      Printf.printf "missing: %d\n" (List.length (load_live ~dir));
      Unix.mkdir dir 0o000;
      (match load_live ~dir with
      | l -> Printf.printf "unreadable: %d records\n" (List.length l)
      | exception Sys_error _ -> print_endline "unreadable: error");
      Unix.chmod dir 0o755;
      [%expect {|
    missing: 0
    unreadable: error
    |}]
  end)
