let create ?scrollback_max_bytes ~cols ~rows () =
  let l = Ko_server.Config.default_limits in
  let scrollback =
    match scrollback_max_bytes with
    | Some n -> Ko_server.Config.Scrollback { max_bytes = Some n; max_lines = None }
    | None -> l.scrollback
  in
  Ko_vt.create ~cols ~rows ~scrollback ~apc_max_bytes:l.apc_max_bytes
    ~kitty_images_max_bytes:l.kitty_images_max_bytes
    ~continuation_max_bytes:l.continuation_max_bytes
