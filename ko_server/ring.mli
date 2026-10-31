type layout = {
  data_offset : int;
  record_header : int;
  bytes_tag : int;
  marker_tag : int;
  slice_tag : int;
  pad_tag : int;
}

val layout : layout

type kind = Bytes | Marker | Slice | Pad
type t

val create : Bigstringaf.t -> t
val buffer : t -> Bigstringaf.t
val head : t -> int
val tail : t -> int
val reachable : t -> int -> int option
val advance : t -> head:int -> keep:int -> unit
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
