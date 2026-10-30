exception Error of string

type t

val of_fd : Unix.file_descr -> t
val close : t -> unit

val request :
  socket:string ->
  ?client:string ->
  ?consume:(string -> unit) ->
  meth:string ->
  path:string ->
  string ->
  string

val upgrade : t -> ?client:string -> path:string -> unit -> unit
val send : t -> Yojson.Safe.t -> unit
val receive : t -> [ `Text of string | `Binary of string | `Close ]
