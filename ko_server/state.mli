type t

val create : Config.t -> t
val panes : t -> Panes.t
val clients : t -> Client.t list
val on_activity : t -> (unit -> unit) -> unit
val topology : t -> unit
val pump : t -> unit
val waiting : t -> bool
val close_views : t -> Pane.t -> unit
val event : t -> Pane.t -> Pane.event -> unit
val add_client : t -> Connection.t -> Client.t
val remove_client : t -> Client.t -> unit
val add_view : t -> View.t -> unit
val remove_view : t -> View.t -> unit
val limits : t -> Config.limits
