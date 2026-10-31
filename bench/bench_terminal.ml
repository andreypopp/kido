let create ?scrollback_max_bytes ~cols ~rows () =
  let limits = Ko_server.Config.default_limits.terminal in
  let limits =
    match scrollback_max_bytes with
    | Some n ->
        {
          limits with
          scrollback = Ko_server.Config.Scrollback { max_bytes = Some n; max_lines = None };
        }
    | None -> limits
  in
  Ko_vt.create ~cols ~rows ~limits
