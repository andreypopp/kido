type server = Down | Up | Mismatch

val tmux_safe : string -> string -> (unit, string) result
val conf_command : string -> string list -> (string, string) result
val user_conf : xdg_config_home:string -> home:string -> (string, string) result
val server_conf : exe:string -> user_conf:string -> (string, string) result
val probe_server : string -> server

val run : tmux:string -> ('a, string) result
(** Execs tmux, so returns only its refusal. *)
