type size = { cols : int; rows : int; cell_w_px : int; cell_h_px : int } [@@deriving equal, yojson]

type limits = {
  scrollback_max_bytes : int;
  apc_max_bytes : int;
  kitty_image_storage_limit : int;
  media : string list;
  continuation_max_bytes : int;
}
[@@deriving yojson]

type server = { started_at : int; pid : int; build : string } [@@deriving yojson]

type version = { protocol : string; vt : string; server : server; terminal : limits }
[@@deriving yojson]

type t = {
  dir : string;
  pane_exe : string;
  terminfo : string;
  shell : string;
  terminal : limits;
  env : string list;
  cwd : string;
}

let protocol = "1.0"
let major = List.hd (String.split_on_char '.' protocol)
let vt = Vt_revision.value
let default_size = { cols = 80; rows = 24; cell_w_px = 8; cell_h_px = 16 }

let limits scrollback_max_bytes =
  {
    scrollback_max_bytes;
    apc_max_bytes = 65 lsl 20;
    kitty_image_storage_limit = 10_000_000;
    media = [];
    continuation_max_bytes = 65 lsl 20;
  }

let valid_size s =
  s.cols > 0 && s.rows > 0
  && List.for_all (fun n -> n >= 0 && n <= 65535) [ s.cols; s.rows; s.cell_w_px; s.cell_h_px ]

let default_dir ~state ~xdg ~home =
  match (state, xdg) with
  | Some s, _ -> s
  | None, Some s -> Filename.concat s "ko"
  | None, None -> Filename.concat home ".local/state/ko"

let socket ~create dir =
  let socket = Filename.concat dir "socket" in
  if String.contains dir ',' then Error "server directory contains a comma"
  else if String.length socket > Fs.sun_path_max then Error "server socket path exceeds 103 bytes"
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

let%test_module "Tests" =
  (module struct
    let%expect_test "directory precedence and size bounds" =
      print_endline (default_dir ~state:None ~xdg:(Some "/state") ~home:"/home");
      Printf.printf "%b %b\n" (valid_size default_size) (valid_size { default_size with cols = 0 });
      [%expect {|
        /state/ko
        true false
        |}]
  end)
