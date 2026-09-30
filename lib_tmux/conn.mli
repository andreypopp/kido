type block = (string list, string) result
type event = Block of block | Notification of string
type parser = Outside | Inside of { id : string; lines : string list }

val step : parser -> string -> parser * event option
val notifications : string list

type t

val connect : string -> t
val run : t -> string -> block
val wait : t -> float -> unit
val close : t -> unit
val quote : string -> string
val follow : t -> string -> unit
val list_panes : t -> (Pane.t list, string) result
val capture_pane : t -> string -> (string list, string) result
val client_state : t -> string -> Exec.client_state option
