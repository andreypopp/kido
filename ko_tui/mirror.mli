type t

val open_view :
  socket:string ->
  client:string ->
  pane:string ->
  limits:Ko_server.Config.limits ->
  notify:(unit -> unit) ->
  t

val close : t -> unit
val send : t -> Yojson.Safe.t -> unit
val delay : t -> float option
val frame : t -> Ko_vt.frame option
val scroll : t -> int -> unit
val bottom : t -> unit
val error : t -> string option
