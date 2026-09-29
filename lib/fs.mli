val mkdir_p : ?perm:int -> string -> unit
val read : string -> string option
val write : ?perm:int -> string -> string -> unit
val remove : string -> unit
