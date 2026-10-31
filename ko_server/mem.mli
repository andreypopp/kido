(** Little-endian reads from a mapped buffer. They do not allocate; [Bigstringaf]'s boxed int32 and
    int64 do. *)

val uint16 : Luv.Buffer.t -> int -> int
val int32 : Luv.Buffer.t -> int -> int
val int64 : Luv.Buffer.t -> int -> int
