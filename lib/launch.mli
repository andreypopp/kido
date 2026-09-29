type server = Down | Up | Mismatch

val tmux_safe : string -> string -> (unit, string) result
val conf_command : string -> string list -> string
val user_conf : xdg_config_home:string -> home:string -> string
val server_conf : exe:string -> user_conf:string -> string
val probe_server : string -> server
val run : tmux:string -> int
