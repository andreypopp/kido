open Ko_server

let report name f =
  try
    match f () with
    | Ok () -> 0
    | Error message ->
        Printf.eprintf "ko %s: %s\n%!" name message;
        1
  with
  | Unix.Unix_error (e, call, path) ->
      Printf.eprintf "ko %s: %s\n%!" name (Fs.unix_message e call path);
      1
  | Failure message | Sys_error message | Invalid_argument message | Yojson.Json_error message ->
      Printf.eprintf "ko %s: %s\n%!" name message;
      1

let dir override =
  match override with
  | Some path -> path
  | None ->
      let env name = Sys.getenv_opt name |> Option.filter (fun s -> not (String.is_empty s)) in
      Config.default_dir ~state:(env "KO_STATE_DIR") ~xdg:(env "XDG_STATE_HOME")
        ~home:(Sys.getenv "HOME")

let server override scrollback shell =
  report "server" (fun () ->
      let shell =
        match shell with
        | Some s -> s
        | None -> Option.value ~default:"/bin/sh" (Sys.getenv_opt "SHELL")
      in
      match Config.shipped () with
      | Error message -> Error message
      | Ok (pane_exe, terminfo) ->
          if scrollback < 0 then Error "scrollback must not be negative"
          else if Filename.is_relative shell then Error "shell must be an absolute path"
          else
            Loop.run
              {
                Config.dir = dir override;
                pane_exe;
                shell;
                terminfo;
                terminal = Config.limits scrollback;
                env = Array.to_list (Unix.environment ());
                cwd = Sys.getcwd ();
              })

let kill override = report "kill-server" (fun () -> Server_stop.stop ~dir:(dir override))

let version () =
  print_endline
    (Yojson.Safe.to_string
       (`Assoc [ ("protocol", `String Config.protocol); ("vt", `String Config.vt) ]));
  0

let () =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let open Cmdliner in
  let bytes =
    Arg.conv
      ( (fun value ->
          try
            let length = String.length value in
            let scale, digits =
              if length = 0 then (1L, value)
              else
                match value.[length - 1] with
                | 'K' -> (1024L, String.sub value 0 (length - 1))
                | 'M' -> (1048576L, String.sub value 0 (length - 1))
                | 'G' -> (1073741824L, String.sub value 0 (length - 1))
                | _ -> (1L, value)
            in
            let n = Stdlib.Int64.of_string digits in
            if
              Int64.compare n 0L < 0 || Int64.compare n (Int64.div (Int64.of_int max_int) scale) > 0
            then Error (`Msg "invalid byte count")
            else Ok (Int64.to_int (Int64.mul n scale))
          with Failure _ -> Error (`Msg "invalid byte count")),
        Format.pp_print_int )
  in
  let directory = Arg.(value & opt (some string) None & info [ "server" ] ~docv:"DIR") in
  let server =
    Cmd.v
      (Cmd.info "server" ~doc:"Run the ko server in the foreground.")
      Term.(
        const server $ directory
        $ Arg.(value & opt bytes (32 lsl 20) & info [ "scrollback" ] ~docv:"BYTES")
        $ Arg.(value & opt (some string) None & info [ "shell" ] ~docv:"PATH"))
  in
  let kill =
    Cmd.v (Cmd.info "kill-server" ~doc:"Stop the ko server.") Term.(const kill $ directory)
  in
  let version =
    Cmd.v
      (Cmd.info "version" ~doc:"Print the protocol and terminal revisions.")
      Term.(const version $ const ())
  in
  exit (Cmd.eval' (Cmd.group (Cmd.info "ko") [ server; kill; version ]))
