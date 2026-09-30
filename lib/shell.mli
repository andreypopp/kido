val user_command_option : string
val command : path:string -> login:string -> string option -> string * string option
val with_env : string array -> (string * string) list -> string array
val argv : string -> Prime.mode -> string option -> string list
val run : unit -> int
