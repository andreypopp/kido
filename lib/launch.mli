val tmux_safe : string -> string -> (unit, string) result

val run : tmux:string -> ('a, string) result
(** Execs tmux, so returns only its refusal. *)
