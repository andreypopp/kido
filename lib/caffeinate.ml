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

let is_caffeinate pid =
  if not (State.alive pid) then false
  else
    let ic = Unix.open_process_args_in "ps" [| "ps"; "-o"; "comm="; "-p"; Int.to_string pid |] in
    let comm = String.trim (In_channel.input_all ic) in
    match Unix.close_process_in ic with
    | Unix.WEXITED 0 -> String.equal (Filename.basename comm) "caffeinate"
    | _ -> false

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
  match (state.mode, busy) with
  | Off, _ -> if state.active then `Stop else `None
  | On, _ | Agents, true -> if (not state.active) || Option.is_some since then `Wake else `None
  | Agents, false -> (
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
                            try if is_caffeinate pid then Unix.kill pid Sys.sigterm
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
                              "caffeinate -i -w %d </dev/null >/dev/null 2>&1 & pid=$!; n=0; \
                               while [ \"$n\" -lt 50 ]; do \
                               case $(ps -o comm= -p \"$pid\") in caffeinate|*/caffeinate) \
                               exec %s -S %s set-option -s @kido-caffeinate-pid \"$pid\" ;; esac; \
                               n=$((n + 1)); sleep 0.01; done; \
                               kill -KILL \"$pid\" 2>/dev/null; wait \"$pid\" 2>/dev/null"
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
