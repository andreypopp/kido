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
      match absent (fun () -> Ko_server.Socket.connect ~socket ~deadline) with
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
              match absent (fun () -> Ko_server.Socket.connect ~socket ~deadline) with
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
                    match absent (fun () -> Ko_server.Socket.connect ~socket ~deadline) with
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
