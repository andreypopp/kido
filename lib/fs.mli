val mkdir_p : ?perm:int -> string -> unit
val read : string -> string option
val write : ?perm:int -> string -> string -> unit
val remove : string -> unit

val unix_message : Unix.error -> string -> string -> string
(** ["fn arg: message"], the text a [Unix_error] is reported as. *)
