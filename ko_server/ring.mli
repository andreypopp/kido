type kind = Bytes | Marker | Slice | Pad
type t

val create : Luv.Buffer.t -> t
val buffer : t -> Luv.Buffer.t
val head : t -> int
val tail : t -> int
val reachable : t -> int -> int option
val advance : t -> head:int -> keep:int -> (unit, string) result
val kind : t -> int -> kind
val next : t -> int -> int
val offset : t -> int -> int
val length : t -> int -> int
val at : t -> int -> int
val slice : t -> int -> Protocol.Record.slice
val marker : t -> int -> Protocol.marker
val end_offset : t -> int
val oldest_offset : t -> int
val resume : t -> int -> int
