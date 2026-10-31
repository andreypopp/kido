type decision = Resume | Snapshot of Protocol.history | Skip
type view

val decide : bool -> int -> int -> Protocol.history -> bool -> bool -> decision
val make_view : Ring.t -> Connection.t -> Delivery_io.view_io -> Protocol.history -> view
val open_view : view -> int option -> unit
val conn : view -> Connection.t
val close : view -> unit
val view_waiting : view -> bool
val request_snapshot : view -> Protocol.history -> unit
val on_slice : view -> int -> int -> unit
val on_done : view -> int -> bool -> unit
val pump : view -> unit
