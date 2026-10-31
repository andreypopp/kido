exception Error of string

type t

val of_fd : Unix.file_descr -> t
val close : t -> unit

val exchange :
  socket:string ->
  ?client:Ko_server.Ids.Client_id.t ->
  ?consume:(string -> unit) ->
  meth:string ->
  path:string ->
  string ->
  string * (string * string) list * string

val request :
  socket:string ->
  ?client:Ko_server.Ids.Client_id.t ->
  ?consume:(string -> unit) ->
  meth:string ->
  path:string ->
  string ->
  string

val upgrade : t -> ?client:Ko_server.Ids.Client_id.t -> path:string -> unit -> unit
val send : t -> Yojson.Basic.t -> unit
val receive : t -> [ `Text of string | `Binary of string | `Close ]
