type t

val create : Ids.Client_id.t -> Connection.t -> t
val id : t -> Ids.Client_id.t
val connection : t -> Connection.t
val registered : t -> bool
val receive : Panes.t -> clients:t list -> t -> Protocol.client_input -> (unit, string) result
