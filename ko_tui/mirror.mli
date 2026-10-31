type t

val open_view :
  socket:string ->
  client:Ko_server.Ids.Client_id.t ->
  pane:Ko_server.Ids.Pane_id.t ->
  limits:Ko_server.Config.limits ->
  notify:(unit -> unit) ->
  t

val close : t -> unit
val send : t -> Yojson.Basic.t -> unit
val delay : t -> float option
val frame : t -> Ko_vt.frame option
val scroll : t -> int -> unit
val bottom : t -> unit
val error : t -> string option
