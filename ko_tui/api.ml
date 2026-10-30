type error = Websocket | No_server | Failed of string

let websocket path =
  let path = List.hd (String.split_on_char '?' path) in
  String.equal path "/client"
  || match String.split_on_char '/' path with [ ""; "panes"; _; "view" ] -> true | _ -> false

let request ~dir ~meth ~path body =
  if websocket path then Error Websocket
  else
    try
      match Ko_server.Config.socket ~create:false dir with
      | Error message -> Error (Failed message)
      | Ok socket -> Ok (Wire.exchange ~socket ~meth ~path body)
    with
    | Unix.Unix_error ((Unix.ENOENT | Unix.ECONNREFUSED), _, _) -> Error No_server
    | Wire.Error message -> Error (Failed message)
