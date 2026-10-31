type token = { req : int; consume : int -> unit; finish : bool -> unit }
type pane_io
type view_io = { request : Protocol.history -> int -> bool }

val req : token -> int
val pane_io_create : unit -> pane_io
val queue_empty : pane_io -> bool
val queue_front : pane_io -> token
val queue_floor : pane_io -> int
val queue_push : pane_io -> token -> int -> unit
val queue_pop : pane_io -> unit
val queue_to_fin : pane_io -> int -> unit
val fin_empty : pane_io -> bool
val fin_front : pane_io -> token
val fin_hold : pane_io -> int
val fin_pop : pane_io -> unit
val slice : token -> int -> unit
val finish : token -> bool -> unit
val slice_last : Ring.t -> int -> bool
val is_resize : Ring.t -> int -> bool
val request : view_io -> Protocol.history -> int -> bool
val reject_io : Connection.t -> unit
val batch_add : Connection.t -> int -> int -> int -> unit
val json_marked : Connection.t -> Ring.t -> int -> int -> unit
val json_skipped : Connection.t -> int -> int -> unit
val record : Connection.t -> Bigstringaf.t -> int -> int -> int -> Connection.written
