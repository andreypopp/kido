val dir : unit -> string
val check_dir : dir:string -> (unit, string) result
val server_socket : create:bool -> dir:string -> (string, string) result
