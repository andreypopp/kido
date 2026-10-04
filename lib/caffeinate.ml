type mode = Off | On | Agents
type t = { mode : mode; active : bool }

let grace () =
  if
    Sys.file_exists "/System/Library/CoreServices/SystemVersion.plist"
    && Option.is_some (Tmux.Exec.look_path ~path:(Tmux.Exec.getenv "PATH") "caffeinate")
  then Some (Timestamp.ms_env Sys.getenv_opt "KIDO_CAFFEINATE_GRACE_MS" 60.)
  else None

let toggle ?socket () =
  Tmux.Exec.run ?socket
    [
      "set-option";
      "-sF";
      "@kido-caffeinate";
      "#{?#{==:#{@kido-caffeinate},on},agents,#{?#{==:#{@kido-caffeinate},agents},off,on}}";
    ]

let read conn =
  let format =
    String.concat "\x1f"
      [
        "#{pid}";
        "#{@kido-caffeinate}";
        "#{@kido-caffeinate-pid}";
        "#{@kido-caffeinate-idle}";
        "#{socket_path}";
      ]
  in
  match Tmux.Conn.run conn ("display-message -p " ^ Filename.quote format) with
  | Ok [ line ] -> (
      match String.split_on_char '\x1f' line with
      | [ server; mode; pid; since; socket ] ->
          Option.map
            (fun server ->
              let mode = match mode with "on" -> On | "agents" -> Agents | _ -> Off in
              let pid = Option.filter (fun p -> p > 0) (Int.of_string pid) in
              ( server,
                { mode; active = Option.exists State.alive pid },
                pid,
                Float.of_string_opt since,
                socket ))
            (Option.filter (fun p -> p > 0) (Int.of_string server))
      | _ -> None)
  | _ -> None

let action ~grace ~now ~busy state since =
  match state.mode with
  | Off -> if state.active then `Stop else `None
  | (On | Agents) when Stdlib.(state.mode = On) || busy ->
      if (not state.active) || Option.is_some since then `Wake else `None
  | On | Agents -> (
      if not state.active then `None
      else
        match since with
        | None -> `Idle
        | Some since -> if Float.(now - since >= grace) then `Stop else `None)

let tick ~dir ~grace ~now ~busy conn =
  match read conn with
  | None -> None
  | Some (server, state, _, since, _) ->
      if Stdlib.(action ~grace ~now ~busy state since = `None) then Some state
      else (
        Fs.mkdir_p dir;
        let fd =
          Unix.openfile
            (Filename.concat dir (Printf.sprintf "caffeinate-%d.lock" server))
            [ Unix.O_CREAT; Unix.O_RDWR ] 0o600
        in
        Fun.protect
          ~finally:(fun () -> Unix.close fd)
          (fun () ->
            let locked =
              try
                Unix.lockf fd Unix.F_TLOCK 0;
                true
              with Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) -> false
            in
            if not locked then Some state
            else
              let set name value = "set-option -s " ^ name ^ " " ^ Filename.quote value in
              Option.iter
                (fun (server, state, pid, since, socket) ->
                  let commands =
                    match action ~grace ~now ~busy state since with
                    | `None -> []
                    | `Idle -> [ set "@kido-caffeinate-idle" (string_of_float now) ]
                    | `Stop ->
                        Option.iter
                          (fun pid ->
                            try Unix.kill pid Sys.sigterm
                            with Unix.Unix_error (Unix.ESRCH, _, _) -> ())
                          pid;
                        [ set "@kido-caffeinate-pid" ""; set "@kido-caffeinate-idle" "" ]
                    | `Wake ->
                        (if Option.is_some since then [ set "@kido-caffeinate-idle" "" ] else [])
                        @
                        if state.active then []
                        else
                          let script =
                            Printf.sprintf
                              "caffeinate -i -w %d </dev/null >/dev/null 2>&1 & %s -S %s \
                               set-option -s @kido-caffeinate-pid $!"
                              server
                              (Filename.quote (Lazy.force Tmux.Exec.binary))
                              (Filename.quote socket)
                          in
                          [ "run-shell " ^ Filename.quote script ]
                  in
                  if not (List.is_empty commands) then
                    ignore (Tmux.Conn.run conn (String.concat " ; " commands)))
                (read conn);
              Option.map (fun (_, state, _, _, _) -> state) (read conn)))
