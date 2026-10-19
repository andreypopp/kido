let dir () =
  let socket =
    (let open Option.Infix in
     let* tmux = Sys.getenv_opt "TMUX" in
     let+ (e : Tmux.env) = Tmux.env_of_string tmux in
     e.socket)
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
  else if String.length socket > Fs.sun_path_max then
    Error
      (Printf.sprintf "server socket path %S is too long (maximum %d bytes)" socket Fs.sun_path_max)
  else begin
    if create then Fs.mkdir_p ~perm:0o700 dir;
    Result.map (fun () -> socket) (check_dir ~dir)
  end

let tmux ~dir = Result.map (fun socket -> Tmux.create ~socket ()) (server_socket ~create:false ~dir)
