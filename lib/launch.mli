type endpoint = {
  tmux : string;
  socket : string;
  protocol : string;
  server : string option;
  expected : string;
}
[@@deriving yojson_of]

val stamp : string

type server = Down | Up of string option | Mismatch

val probe_server : socket:string -> string -> server

val run : dir:string -> env:string array -> inside:Tmux.env option -> ('a, string) result
(** Execs tmux, so returns only its refusal. *)

val ensure : dir:string -> env:string array -> (endpoint, string) result
(** Starts the kido server detached unless one is up, and reports where it is. *)
