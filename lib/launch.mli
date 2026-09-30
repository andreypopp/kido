type endpoint = { tmux : string; socket : string } [@@deriving to_yojson]

val tmux_safe : string -> string -> (unit, string) result

val run : tmux:string -> ('a, string) result
(** Execs tmux, so returns only its refusal. *)

val ensure : unit -> (endpoint, string) result
(** Starts the kido server detached unless one is up, and reports where it is. *)
