type ssh_args = { opts : string list; letters : string; dest : string; command : string list }

val split_fields : string -> string list list
val parse_ssh : string list -> ssh_args option
