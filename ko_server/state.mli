type t

val create : Config.t -> activity:(unit -> unit) -> t
val panes : t -> Panes.t
val clients : t -> Client.t list
val topology : t -> unit
val pump : t -> unit
val waiting : t -> bool
val close_views : t -> Ids.Pane_id.t -> unit
val event : t -> Ids.Pane_id.t -> Pane_proc.event -> unit
val add_client : t -> Connection.t -> Client.t
val remove_client : t -> Client.t -> unit
val add_view : t -> View.t -> unit
val remove_view : t -> View.t -> unit
val limits : t -> Config.limits
val registered : t -> Ids.Client_id.t -> bool
