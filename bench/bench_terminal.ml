let create ?scrollback_max_bytes ~cols ~rows () =
  let l = Ko_server.Config.limits ?scrollback_max_bytes () in
  Ko_vt.create ~cols ~rows ~scrollback_max_bytes:l.scrollback_max_bytes
    ~scrollback_max_lines:l.scrollback_max_lines ~apc_max_bytes:l.apc_max_bytes
    ~kitty_image_storage_limit:l.kitty_image_storage_limit
    ~continuation_max_bytes:l.continuation_max_bytes
