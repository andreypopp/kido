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
  Luv.Buffer.t ->
  at:int ->
  len:int ->
  written

val upgrade :
  t ->
  Httpun.Reqd.t ->
  (Gluten.impl -> unit) ->
  on_text:(string -> unit) ->
  on_close:(unit -> unit) ->
  on_writable:(unit -> unit) ->
  (unit, string) result

val writer : Unix.file_descr -> t
val accept : Luv.Pipe.t -> on_dispose:(t -> unit) -> (t -> Httpun.Reqd.t Gluten.reqd -> unit) -> t
val tick : t -> float -> unit
