type error = Websocket | No_server | Failed of string

val request :
  dir:string ->
  meth:string ->
  path:string ->
  string ->
  (string * (string * string) list * string, error) result
