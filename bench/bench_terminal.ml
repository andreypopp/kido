let create ?scrollback_max_bytes ~cols ~rows () =
  let limits =
    match scrollback_max_bytes with
    | Some n -> (Ko_server.Config.scrollback_limits n).terminal
    | None -> Ko_server.Config.default_limits.terminal
  in
  Ko_vt.create ~cols ~rows ~limits
