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

let default_bytes, default_lines =
  match Config.default_scrollback with
  | Scrollback { max_bytes; max_lines } -> (max_bytes, max_lines)
  | Scrollback_disabled -> (None, None)

let show_limit = function Some n -> string_of_int n | None -> "unlimited"

let scrollback bytes lines disabled =
  match (disabled, bytes, lines) with
  | true, None, None -> Ok Config.Scrollback_disabled
  | true, _, _ ->
      Error (`Msg "--no-scrollback conflicts with --scrollback-bytes and --scrollback-lines")
  | false, _, _ ->
      Ok
        (Config.Scrollback
           {
             max_bytes = Option.value ~default:default_bytes bytes;
             max_lines = Option.value ~default:default_lines lines;
           })

let server override scrollback shell =
  report "server" (fun () ->
      Result.flat_map Loop.run (Config.create ~dir:override ~shell ~scrollback))

let attach override =
  report "attach" (fun () ->
      let pager =
        Sys.getenv_opt "PAGER"
        |> Option.filter (fun p -> not (String.is_empty p))
        |> Option.value ~default:"less -R +G -+F"
      in
      Ko_tui.run ~dir:(Config.dir ~dir:override) ~executable:(Lazy.force Fs.self) ~pager)

let kill override =
  report "kill-server" (fun () -> Ko_tui.Launch.stop ~dir:(Config.dir ~dir:override))

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
        let dir = Config.dir ~dir:override in
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
        | Ok { status; reason; headers; body } ->
            if include_headers then
              print_string
                (String.concat "\r\n"
                   (Printf.sprintf "HTTP/1.1 %d %s" status reason
                   :: List.map (fun (name, value) -> name ^ ": " ^ value) headers)
                ^ "\r\n\r\n");
            print_string body;
            flush stdout;
            if status / 100 = 2 then 0
            else (
              Printf.eprintf "ko api: HTTP %d\n%!" status;
              1))

let version () =
  print_endline (Yojson.Basic.to_string (Protocol.version_to_json Protocol.version));
  0

let () =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let open Cmdliner in
  let unlimited convert =
    Arg.conv
      ( (fun value ->
          if String.equal value "unlimited" then Ok None
          else Result.map Option.some (Arg.conv_parser convert value)),
        fun ppf -> function
          | None -> Format.pp_print_string ppf "unlimited" | Some n -> Format.pp_print_int ppf n )
  in
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
              Int64.compare n 1L < 0 || Int64.compare n (Int64.div (Int64.of_int max_int) scale) > 0
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
        $ term_result
            (const scrollback
            $ Arg.(
                value
                & opt (some (unlimited bytes)) None
                & info [ "scrollback-bytes" ] ~docv:"BYTES|unlimited"
                    ~doc:
                      (Printf.sprintf "Scrollback limit in bytes. The default is %s."
                         (show_limit default_bytes)))
            $ Arg.(
                value
                & opt (some (unlimited positive)) None
                & info [ "scrollback-lines" ] ~docv:"N|unlimited"
                    ~doc:
                      (Printf.sprintf "Scrollback limit in lines. The default is %s."
                         (show_limit default_lines)))
            $ Arg.(
                value & flag
                & info [ "no-scrollback" ]
                    ~doc:"Keep no scrollback. This conflicts with the two scrollback limits."))
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
