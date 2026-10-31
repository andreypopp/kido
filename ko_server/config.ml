type scrollback = Ko_vt.scrollback =
  | Scrollback_disabled [@json.name "disabled"]
  | Scrollback of {
      max_bytes : int option; [@json.option] [@json.drop_default]
      max_lines : int option; [@json.option] [@json.drop_default]
    } [@json.name "scrollback"]
[@@deriving json] [@@json.compact_variants]

type medium =
  | File [@json.name "file"]
  | Temp_file [@json.name "temp_file"]
  | Shared_mem [@json.name "shared_mem"]
[@@deriving json] [@@json.compact_variants]

type terminal = Ko_vt.limits = {
  scrollback : scrollback;
  apc_max_bytes : int;
  kitty_images_max_bytes : int;
  continuation_max_bytes : int;
}
[@@deriving json]

type limits = { terminal : terminal; media : medium list } [@@deriving json]

type t = {
  dir : string;
  socket : string;
  pane_exe : string;
  terminfo : string;
  shell : string;
  limits : limits;
  env : string list;
  cwd : string;
}

let build =
  match Build_info.V1.version () with
  | Some v -> Build_info.V1.Version.to_string v
  | None -> "unknown"

let default_scrollback = Scrollback { max_bytes = Some 50_000_000; max_lines = None }

let default_limits =
  {
    terminal =
      {
        scrollback = default_scrollback;
        apc_max_bytes = 65 lsl 20;
        kitty_images_max_bytes = 10_000_000;
        continuation_max_bytes = 65 lsl 20;
      };
    media = [];
  }

let dir ~dir:override =
  let env name = Sys.getenv_opt name |> Option.filter (fun s -> not (String.is_empty s)) in
  match (override, env "KO_STATE_DIR", env "XDG_STATE_HOME") with
  | Some path, _, _ | None, Some path, _ -> path
  | None, None, Some xdg -> Filename.concat xdg "ko"
  | None, None, None ->
      let home =
        match env "HOME" with Some h -> h | None -> (Unix.getpwuid (Unix.getuid ())).pw_dir
      in
      Filename.concat home ".local/state/ko"

let socket ~create ~dir =
  let socket = Filename.concat dir "socket" in
  if String.contains dir ',' then Error "server directory contains a comma"
  else if String.length socket > Fs.sun_path_max then
    Error (Printf.sprintf "server socket path exceeds %d bytes" Fs.sun_path_max)
  else begin
    if create then Fs.mkdir_p ~perm:0o700 dir;
    let st = Unix.lstat dir in
    if match st.st_kind with Unix.S_DIR -> false | _ -> true then
      Error "server path is not a directory"
    else if st.st_uid <> Unix.getuid () then Error "server directory is not owned by this user"
    else if st.st_perm land 0o077 <> 0 then Error "server directory is accessible to other users"
    else Ok socket
  end

let shipped () =
  let candidates = Fs.candidates (Lazy.force Fs.self) in
  let pane_exe =
    List.find_map
      (fun exe ->
        let path = Filename.concat (Filename.dirname exe) "ko-pane" in
        if Fs.is_executable path then Some path else None)
      candidates
  in
  let terminfo =
    List.find_map
      (fun exe ->
        let path = Filename.concat (Filename.dirname exe) "../share/ko/terminfo" in
        if Sys.file_exists path then Some path else None)
      candidates
  in
  match pane_exe with
  | None -> Error "ko-pane was not found beside ko"
  | Some pane_exe ->
      Ok
        ( pane_exe,
          Option.value
            ~default:(Filename.concat (Filename.dirname pane_exe) "../share/ko/terminfo")
            terminfo )

let create ~dir:override ~shell ~scrollback =
  let open Result.Infix in
  let shell =
    match shell with
    | Some s -> s
    | None -> (
        match Sys.getenv_opt "SHELL" with
        | Some s when not (String.is_empty s) -> s
        | _ -> "/bin/sh")
  in
  let* pane_exe, terminfo = shipped () in
  let* () = if Filename.is_relative shell then Error "shell must be an absolute path" else Ok () in
  let dir = dir ~dir:override in
  let+ socket = socket ~create:true ~dir in
  {
    dir;
    socket;
    pane_exe;
    terminfo;
    shell;
    limits = { default_limits with terminal = { default_limits.terminal with scrollback } };
    env = Array.to_list (Unix.environment ());
    cwd = Sys.getcwd ();
  }
