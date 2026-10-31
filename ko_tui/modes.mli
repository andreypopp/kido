type t

val save : unit -> t * Matrix_input.t list
val apply : t -> Ko_vt.frame -> string
val reset : t -> unit
val restore : t -> unit
