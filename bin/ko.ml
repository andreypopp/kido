open Ko_server

let run name f =
  try f () with
  | Unix.Unix_error (e, call, path) ->
      Printf.eprintf "ko %s: %s\n%!" name (Fs.unix_message e call path);
      1
  | Failure message | Sys_error message | Invalid_argument message | Yojson.Json_error message ->
      Printf.eprintf "ko %s: %s\n%!" name message;
      1

let report name f =
  run name (fun () ->
      match f () with
      | Ok () -> 0
      | Error message ->
          Printf.eprintf "ko %s: %s\n%!" name message;
          1)

let dir override =
  match override with
  | Some path -> path
  | None ->
      let env name = Sys.getenv_opt name |> Option.filter (fun s -> not (String.is_empty s)) in
      Config.default_dir ~state:(env "KO_STATE_DIR") ~xdg:(env "XDG_STATE_HOME")
        ~home:(Sys.getenv "HOME")

let server override scrollback lines shell =
  report "server" (fun () ->
      let shell =
        match shell with
        | Some s -> s
        | None -> Option.value ~default:"/bin/sh" (Sys.getenv_opt "SHELL")
      in
      match Config.shipped () with
      | Error message -> Error message
      | Ok (pane_exe, terminfo) ->
          if Filename.is_relative shell then Error "shell must be an absolute path"
          else
            Loop.run
              {
                Config.dir = dir override;
                pane_exe;
                shell;
                terminfo;
                terminal =
                  Config.limits ~scrollback_max_bytes:scrollback ?scrollback_max_lines:lines ();
                env = Array.to_list (Unix.environment ());
                cwd = Sys.getcwd ();
              })

let attach override =
  report "attach" (fun () ->
      let pager =
        Sys.getenv_opt "PAGER"
        |> Option.filter (fun p -> not (String.is_empty p))
        |> Option.value ~default:"less -R +G -+F"
      in
      Ko_tui.run ~dir:(dir override) ~executable:(Lazy.force Fs.self) ~pager)

let kill override = report "kill-server" (fun () -> Server_stop.stop ~dir:(dir override))

let api override meth input include_headers path =
  run "api" (fun () ->
      let body =
        match input with
        | None -> ""
        | Some "-" -> IO.read_all stdin
        | Some file -> IO.File.read_exn file
      in
      let meth =
        String.uppercase_ascii
          (match (meth, input) with Some m, _ -> m | None, Some _ -> "POST" | None, None -> "GET")
      in
      if not (String.starts_with ~prefix:"/" path) then (
        prerr_endline "ko api: path must start with /";
        1)
      else
        let dir = dir override in
        match Ko_tui.Api.request ~dir ~meth ~path body with
        | Error Websocket ->
            Printf.eprintf
              "ko api: %s is a WebSocket endpoint; ko api sends one request and prints one response\n\
               %!"
              path;
            2
        | Error No_server ->
            Printf.eprintf "ko api: no server at %s\n%!" dir;
            1
        | Error (Failed message) ->
            Printf.eprintf "ko api: %s\n%!" message;
            1
        | Ok (status, fields, response) ->
            if include_headers then
              print_string
                (String.concat "\r\n"
                   (status :: List.map (fun (name, value) -> name ^ ": " ^ value) fields)
                ^ "\r\n\r\n");
            print_string response;
            flush stdout;
            if String.starts_with ~prefix:"HTTP/1.1 2" status then 0
            else (
              Printf.eprintf "ko api: HTTP %s\n%!" (List.nth (String.split_on_char ' ' status) 1);
              1))

let version () =
  print_endline
    (Yojson.Safe.to_string
       (`Assoc
          [
            ("protocol", `String Config.protocol);
            ("vt", `String Config.vt);
            ("build", `String Config.build);
          ]));
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
  let positive =
    Arg.conv
      ( (fun value ->
          match int_of_string_opt value with
          | Some n when n > 0 -> Ok n
          | _ -> Error (`Msg "invalid line count")),
        Format.pp_print_int )
  in
  let directory = Arg.(value & opt (some string) None & info [ "server" ] ~docv:"DIR") in
  let server =
    Cmd.v
      (Cmd.info "server" ~doc:"Run the ko server in the foreground.")
      Term.(
        const server $ directory
        $ Arg.(
            value
            & opt bytes Config.default_scrollback_bytes
            & info [ "scrollback-bytes" ] ~docv:"BYTES")
        $ Arg.(value & opt (some positive) None & info [ "scrollback-lines" ] ~docv:"N")
        $ Arg.(value & opt (some string) None & info [ "shell" ] ~docv:"PATH"))
  in
  let kill =
    Cmd.v (Cmd.info "kill-server" ~doc:"Stop the ko server.") Term.(const kill $ directory)
  in
  let version =
    Cmd.v
      (Cmd.info "version" ~doc:"Print the build, protocol and terminal revisions.")
      Term.(const version $ const ())
  in
  let api =
    Cmd.v
      (Cmd.info "api" ~doc:"Send one HTTP request to the ko server and print the response."
         ~man:
           [
             `S Manpage.s_description;
             `P
               "Sends $(b,PATH), which starts with $(b,/), to the ko server and prints the \
                response body. Query strings pass through. The command never starts a server. It \
                exits 0 on a 2xx status. On any other status it still prints the body, writes \
                $(b,ko api: HTTP) and the status to stderr and exits 1. It refuses a WebSocket \
                endpoint ($(b,/client) and $(b,/panes/ID/view)) and exits 2.";
           ])
      Term.(
        const api $ directory
        $ Arg.(
            value
            & opt (some string) None
            & info [ "method"; "X" ] ~docv:"METHOD"
                ~doc:"The HTTP method. The default is GET, or POST with $(b,--input).")
        $ Arg.(
            value
            & opt (some string) None
            & info [ "input" ] ~docv:"FILE"
                ~doc:"Send the file as the request body. $(b,-) reads standard input.")
        $ Arg.(
            value & flag
            & info [ "include"; "i" ] ~doc:"Print the status line and headers before the body.")
        $ Arg.(required & pos 0 (some string) None & info [] ~docv:"PATH"))
  in
  exit
    (Cmd.eval'
       (Cmd.group
          ~default:Term.(const attach $ directory)
          (Cmd.info "ko") [ server; kill; version; api ]))
