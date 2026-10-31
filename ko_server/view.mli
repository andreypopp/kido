type t

val create :
  Pane.t -> Connection.t -> client:Ids.Client_id.t option -> offset:int option -> full:bool -> t

val client : t -> Ids.Client_id.t option
val pane : t -> Pane.t
val waiting : t -> bool
val pump : t -> unit
val receive : t -> string -> unit
val close : t -> unit
