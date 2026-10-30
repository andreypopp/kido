type t

val create : string -> Connection.t -> t
val id : t -> string
val connection : t -> Connection.t
val registered : t -> bool
val receive : Panes.t -> clients:t list -> t -> Protocol.client_input -> (unit, string) result
