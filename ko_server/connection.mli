type t
type written = Accepted | Blocked of bool | Closed

val close : t -> unit
val reject : t -> Protocol.error_kind -> unit
val json : t -> Yojson.Basic.t -> unit
val is_closed : t -> bool
val available : t -> bool
val waiting : t -> bool

val record :
  t -> queue:bool -> kind:int -> offset:int -> Luv.Buffer.t -> at:int -> len:int -> written

val upgrade :
  t ->
  Httpun.Reqd.t ->
  (Gluten.impl -> unit) ->
  on_text:(string -> unit) ->
  on_close:(unit -> unit) ->
  on_writable:(unit -> unit) ->
  (unit, string) result

val respond : Httpun.Reqd.t -> Httpun.Status.t -> string -> unit
val error : Httpun.Reqd.t -> Httpun.Status.t -> Protocol.error_kind -> string -> unit
val body : Httpun.Reqd.t -> (Yojson.Basic.t -> unit) -> unit
val writer : Unix.file_descr -> t
val accept : Luv.Pipe.t -> on_dispose:(t -> unit) -> (t -> Httpun.Reqd.t Gluten.reqd -> unit) -> t
val tick : t -> float -> unit
