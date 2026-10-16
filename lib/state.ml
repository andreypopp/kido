let display_name panes (s : Subrun.pi) =
  if not (String.is_empty s.name) then s.name
  else
    Option.map_or ~default:""
      (fun (p : Tmux_pane.t) -> p.title)
      (Option.flat_map (Tmux_pane.find panes) s.pane)

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

let runs ~dir panes =
  List.fold_left
    (fun m (p : Tmux_pane.t) ->
      Option.map_or ~default:m
        (fun r -> Tmux.Pane_map.add p.pane_id r m)
        (Option.flat_map (Subrun.load ~dir) p.run))
    Tmux.Pane_map.empty panes

let run_pane ~(runs : Subrun.run Tmux.Pane_map.t) panes window =
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
    (fun pane (r : Subrun.run) ->
      Subrun.holder r
      |> Option.filter (fun (s : Subrun.pi) -> Option.equal Tmux.equal_pane_id s.pane (Some pane))
      |> Option.map (fun s -> (Subrun.string_of_id r.meta.id, s)))
    runs

type ssh_kind = Remote_terminal | Remote_agent of { name : string }

type pane_kind =
  | Terminal
  | Some_agent of { name : string }
  | Pi_agent of { id : string; pi : Subrun.pi }
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
      | Some (id, pi) -> Pi_agent { id; pi }
      | None -> Some_agent { name = "pi" })
  | _, _, Some "claude-code" -> Some_agent { name = "claude-code" }
  | _ -> Terminal

let pane_title (p : Tmux_pane.t) = function
  | Ssh { pane = Remote_terminal; _ } -> None
  | Ssh { pane = Remote_agent { name }; _ } ->
      Some (if String.is_empty p.title then name else p.title)
  | Terminal -> None
  | Pi_agent { pi; _ } -> Some (display_name [ p ] pi)
  | Some_agent { name } -> Some (if String.is_empty p.title then name else p.title)

let stall_threshold () = Timestamp.ms_env Sys.getenv_opt "KIDO_STALL_THRESHOLD_MS" 180.

let stalled_since ~root ~threshold ~wake ~now (s : Subrun.pi) =
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
    open Tmux_pane_fixture

    let temp () = Filename.temp_dir "kido-state" ""

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
      let states = Tmux.Pane_map.singleton p.pane_id ("local", Test_fixture.pi ()) in
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
  end)
