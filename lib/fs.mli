val getenv : string -> string
val is_file : string -> bool
val is_executable : string -> bool
val look_path : path:string -> string -> string option
val invoked_path : path:string -> string -> string
val candidates : string -> string list
val abs : string -> string

val self : string Lazy.t
(** This executable as invoked ({!invoked_path} of [argv.(0)] on [$PATH]), unresolved. *)

val write_all : Unix.file_descr -> string -> unit
val mkdir_p : ?perm:int -> string -> unit
val read : string -> string option
val read_json : string -> (Yojson.Safe.t -> 'a) -> 'a option
val write : ?perm:int -> string -> string -> unit
val remove : string -> unit

val write_temp : ?perm:int -> string -> string -> (string -> string -> unit) -> unit
(** Writes [data] to a fresh temp file beside [path], then calls [place tmp path]. *)

val write_atomic : ?perm:int -> string -> string -> unit

val unix_message : Unix.error -> string -> string -> string
(** ["fn arg: message"], the text a [Unix_error] is reported as. *)
