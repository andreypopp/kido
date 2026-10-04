type endpoint = { tmux : string; socket : string; build : string option } [@@deriving to_yojson]

val tmux_safe : string -> string -> (unit, string) result

val run : dir:string -> tmux:string -> ('a, string) result
(** Execs tmux, so returns only its refusal. *)

val ensure : dir:string -> (endpoint, string) result
(** Starts the kido server detached unless one is up, and reports where it is. *)
