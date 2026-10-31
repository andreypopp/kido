type t

val create : Config.t -> t
val find : t -> Ids.Pane_id.t -> Pane.t option
val rows : t -> Protocol.row list
val iter : t -> (Pane.t -> unit) -> unit

val add :
  t ->
  Protocol.Request.create_pane ->
  notify:(Pane.t -> Pane.event -> unit) ->
  (Pane.t, string) result

val remove : t -> Pane.t -> unit
val shutdown : t -> unit
val kill : t -> unit
val reap : t -> unit
