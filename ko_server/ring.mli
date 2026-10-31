type data =
  | Bytes
  | Resize_marker of Protocol.size
  | Dead_marker of Protocol.dead
  | Slice of Protocol.Record.slice

type record = private { pos : int; next : int; offset : int; at : int; len : int; data : data }
type t

val create : Luv.Buffer.t -> t
val buffer : t -> Luv.Buffer.t
val position : t -> int
val tail : t -> int
val offset : t -> int
val oldest : t -> int
val dead : t -> Protocol.dead option
val pending : t -> bool
val scan : t -> (record -> unit) -> (bool, string) result
val iter_from : t -> int -> (record -> bool) -> unit
val resume : t -> int -> int
