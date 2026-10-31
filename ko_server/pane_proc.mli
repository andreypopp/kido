type life = Open | Closed | Reaped
type event = Title | Pwd | Output | Dead of Protocol.dead
type t

val create :
  Config.t ->
  id:Ids.Pane_id.t ->
  cwd:string ->
  argv:string list ->
  env:string list ->
  notify:(event -> unit) ->
  t

val ring : t -> Ring.t
val life : t -> life
val pid : t -> int
val child_pid : t -> int option
val title : t -> string
val cwd : t -> string
val dead : t -> Protocol.dead option
val busy : t -> bool
val scan : t -> bool
val resize : t -> Protocol.size -> unit

val input :
  t ->
  Protocol.Request.input ->
  ((Protocol.paste_result option, string) result -> unit) ->
  (unit, string) result

val snapshot :
  t ->
  history:Protocol.history ->
  consume:(int -> unit) ->
  done_:((unit, string) result -> unit) ->
  unit

val screen :
  t ->
  format:Protocol.Request.screen_format ->
  history:Protocol.Request.screen_history ->
  chunk:(string -> last:bool -> unit) ->
  done_:((unit, string) result -> unit) ->
  unit

val shutdown : t -> unit
val reap : t -> unit
val kill : t -> unit
