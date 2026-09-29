val temp : unit -> string
val write : ?perm:int -> string -> string -> string
val run : ?stdin:string -> env:string list -> string -> string list -> Unix.process_status * string
val output : ?stdin:string -> env:string list -> string -> string list -> string
