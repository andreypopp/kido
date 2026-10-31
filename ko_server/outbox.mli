type t
type flushed = Done | Blocked | Failed

val create : unit -> t
val add : t -> string -> unit
val is_empty : t -> bool
val bytes : t -> int
val flush : t -> Unix.file_descr -> flushed
