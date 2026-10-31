let connect ~socket ~deadline =
  let fd = Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  try
    Unix.set_nonblock fd;
    let rec dial () =
      try Unix.connect fd (Unix.ADDR_UNIX socket) with
      | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
          let remaining = deadline -. Unix.gettimeofday () in
          if Float.(remaining <= 0.) then
            raise (Unix.Unix_error (Unix.ETIMEDOUT, "connect", socket));
          ignore (Unix.select [] [] [] (Float.min remaining 0.01));
          dial ()
      | Unix.Unix_error (Unix.EINPROGRESS, _, _) -> (
          let remaining = deadline -. Unix.gettimeofday () in
          if Float.(remaining <= 0.) then
            raise (Unix.Unix_error (Unix.ETIMEDOUT, "connect", socket));
          let _, writable, _ = Unix.select [] [ fd ] [] remaining in
          if List.is_empty writable then raise (Unix.Unix_error (Unix.ETIMEDOUT, "connect", socket));
          match Unix.getsockopt_error fd with
          | None -> ()
          | Some e -> raise (Unix.Unix_error (e, "connect", socket)))
    in
    dial ();
    Unix.clear_nonblock fd;
    fd
  with e ->
    Unix.close fd;
    raise e

let attach ~dir ~executable =
  match Ko_server.Config.socket ~create:true ~dir with
  | Error message -> Error message
  | Ok socket -> (
      let deadline = Unix.gettimeofday () +. 5. in
      let absent f =
        try `Connected (f ()) with
        | Unix.Unix_error (Unix.ENOENT, _, _) -> `Missing
        | Unix.Unix_error (Unix.ECONNREFUSED, _, _) -> `Refused
      in
      match absent (fun () -> connect ~socket ~deadline) with
      | `Connected fd -> Ok (socket, fd)
      | `Missing | `Refused ->
          let lock =
            Unix.openfile
              (Filename.concat dir "launch.lock")
              [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_CLOEXEC ]
              0o600
          in
          Fun.protect
            ~finally:(fun () -> Unix.close lock)
            (fun () ->
              let rec acquire () =
                try Unix.lockf lock Unix.F_TLOCK 0
                with Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) ->
                  if Float.(Unix.gettimeofday () >= deadline) then
                    raise (Unix.Unix_error (Unix.ETIMEDOUT, "launch lock", dir));
                  ignore (Unix.select [] [] [] 0.01);
                  acquire ()
              in
              acquire ();
              match absent (fun () -> connect ~socket ~deadline) with
              | `Connected fd -> Ok (socket, fd)
              | (`Missing | `Refused) as state ->
                  (match state with
                  | `Refused -> (
                      try Unix.unlink socket with Unix.Unix_error (Unix.ENOENT, _, _) -> ())
                  | `Missing -> ());
                  let log =
                    Unix.openfile (Filename.concat dir "log")
                      [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND; Unix.O_CLOEXEC ]
                      0o600
                  in
                  let pid =
                    Fun.protect
                      ~finally:(fun () -> Unix.close log)
                      (fun () ->
                        match Unix.fork () with
                        | 0 -> (
                            try
                              ignore (Unix.setsid ());
                              Unix.dup2 log Unix.stdin;
                              Unix.dup2 log Unix.stdout;
                              Unix.dup2 log Unix.stderr;
                              Unix.close lock;
                              Unix.close log;
                              Unix.execv executable [| executable; "server"; "--server"; dir |]
                            with _ -> Unix._exit 127)
                        | pid -> pid)
                  in
                  let rec ready () =
                    match absent (fun () -> connect ~socket ~deadline) with
                    | `Connected fd -> Ok (socket, fd)
                    | `Missing | `Refused -> (
                        match Unix.waitpid [ Unix.WNOHANG ] pid with
                        | 0, _ ->
                            if Float.(Unix.gettimeofday () >= deadline) then
                              Error
                                ("server did not start within 5 seconds; see "
                               ^ Filename.concat dir "log")
                            else (
                              ignore (Unix.select [] [] [] 0.01);
                              ready ())
                        | _ -> Error ("server exited; see " ^ Filename.concat dir "log"))
                  in
                  ready ()))

let stop ~dir =
  match Ko_server.Config.socket ~create:false ~dir with
  | Error message -> Error message
  | Ok socket ->
      let fd = connect ~socket ~deadline:(Unix.gettimeofday () +. 5.) in
      let uid, pid =
        Fun.protect
          ~finally:(fun () -> Unix.close fd)
          (fun () -> (Ko_server.Uv.peer_uid fd, Ko_server.Uv.peer_pid fd))
      in
      if uid <> Unix.getuid () then Error "server belongs to another user"
      else if not (Ko_server.Uv.signalable pid) then Error "invalid server pid"
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
