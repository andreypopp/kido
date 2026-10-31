type error = Websocket | No_server | Failed of string

let request ~dir ~meth ~path body =
  let route =
    try Ko_server.Protocol.Route.of_request ~meth path with Invalid_argument _ -> None
  in
  if Option.exists Ko_server.Protocol.Route.websocket route then Error Websocket
  else
    try
      match Ko_server.Config.socket ~create:false ~dir with
      | Error message -> Error (Failed message)
      | Ok socket -> Ok (Wire.exchange ~socket ~meth ~path body)
    with
    | Unix.Unix_error ((Unix.ENOENT | Unix.ECONNREFUSED), _, _) -> Error No_server
    | Wire.Error message -> Error (Failed message)
