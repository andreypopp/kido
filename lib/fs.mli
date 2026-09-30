val mkdir_p : ?perm:int -> string -> unit
val read : string -> string option
val write : ?perm:int -> string -> string -> unit
val remove : string -> unit

val write_temp : ?perm:int -> string -> string -> (string -> string -> unit) -> unit
(** Writes [data] to a fresh temp file beside [path], then calls [place tmp path]. *)

val write_atomic : ?perm:int -> string -> string -> unit

val unix_message : Unix.error -> string -> string -> string
(** ["fn arg: message"], the text a [Unix_error] is reported as. *)
