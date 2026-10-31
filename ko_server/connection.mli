type t
type written = Accepted | Queued | Blocked | Closed

val max_message : int
val close : t -> unit
val reject : t -> Protocol.error_kind -> unit
val json : t -> Yojson.Basic.t -> unit
val is_closed : t -> bool
val available : t -> bool
val waiting : t -> bool

val record :
  t ->
  queue:bool ->
  kind:Protocol.Record.kind ->
  offset:int ->
  Bigstringaf.t ->
  at:int ->
  len:int ->
  written

val batch_count : t -> int
val batch_capacity : int
val batch_full : t -> bool
val batch_add : t -> offset:int -> at:int -> len:int -> unit
val batch_send : t -> Bigstringaf.t -> int

val upgrade :
  t ->
  Httpun.Reqd.t ->
  (Gluten.impl -> unit) ->
  on_text:(string -> unit) ->
  on_close:(unit -> unit) ->
  on_writable:(unit -> unit) ->
  (unit, string) result

val writer : Unix.file_descr -> t

val accept :
  Unix.file_descr -> on_dispose:(t -> unit) -> (t -> Httpun.Reqd.t Gluten.reqd -> unit) -> t

val tick : t -> float -> unit
