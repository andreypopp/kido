type pane
type scanned = Unchanged | Changed | Aborted

val make : Ring.t -> Delivery_io.pane_io -> pane
val ring : pane -> Ring.t
val busy : pane -> bool
val deliver : pane -> int -> bool
val note_snapshot : pane -> Delivery_io.token -> unit
val snapshot_done : pane -> int -> unit
val fail_requests : pane -> unit
val scan : pane -> bool -> scanned
