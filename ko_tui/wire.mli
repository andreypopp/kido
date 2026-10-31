exception Error of string

type t

val of_fd : Unix.file_descr -> t
val close : t -> unit

type response = { status : int; reason : string; headers : (string * string) list; body : string }

val exchange :
  socket:string ->
  ?client:Ko_server.Ids.Client_id.t ->
  ?consume:(string -> unit) ->
  meth:string ->
  path:string ->
  string ->
  response

val request :
  socket:string ->
  ?client:Ko_server.Ids.Client_id.t ->
  ?consume:(string -> unit) ->
  route:Ko_server.Protocol.Route.t ->
  string ->
  string

val upgrade :
  t -> ?client:Ko_server.Ids.Client_id.t -> route:Ko_server.Protocol.Route.t -> unit -> unit

val send : t -> Yojson.Basic.t -> unit
val receive : t -> [ `Text of string | `Binary of string | `Close ]
