let stop ~dir =
  match Config.socket ~create:false dir with
  | Error message -> Error message
  | Ok socket ->
      let fd = Socket.connect ~socket ~deadline:(Unix.gettimeofday () +. 5.) in
      let uid, pid =
        Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> (Uv.peer_uid fd, Uv.peer_pid fd))
      in
      if uid <> Unix.getuid () then Error "server belongs to another user"
      else if pid <= 0 then Error "invalid server pid"
      else (
        Unix.kill pid Sys.sigterm;
        let deadline = Unix.gettimeofday () +. 5. in
        let alive () =
          Sys.file_exists socket
          ||
          match Unix.kill pid 0 with
          | () -> true
          | exception Unix.Unix_error (Unix.ESRCH, _, _) -> false
        in
        let rec wait () =
          if not (alive ()) then Ok ()
          else if Float.(Unix.gettimeofday () >= deadline) then
            Error "server did not stop within 5 s"
          else (
            ignore (Unix.select [] [] [] 0.01);
            wait ())
        in
        wait ())
