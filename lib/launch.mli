type endpoint = { tmux : string; socket : string; protocol : string; server : string option }
[@@deriving to_yojson]

type server = Down | Up of string option | Mismatch

val probe_server : socket:string -> string -> server
val tmux_safe : string -> string -> (unit, string) result

val run : dir:string -> tmux:string -> ('a, string) result
(** Execs tmux, so returns only its refusal. *)

val ensure : dir:string -> (endpoint, string) result
(** Starts the kido server detached unless one is up, and reports where it is. *)
