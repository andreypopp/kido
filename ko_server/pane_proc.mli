type data =
  | Bytes
  | Resize_marker of Protocol.size
  | Dead_marker of Protocol.dead
  | Slice of Protocol.Record.slice

type record = private { pos : int; next : int; offset : int; at : int; len : int; data : data }

type event =
  | Ready_pid of int
  | Title_changed of string
  | Pwd_changed of string
  | Record of record
  | Published
  | Exited
  | Failed of Protocol.dead

type t

val create :
  ?callbacks:bool ->
  Config.t ->
  id:Ids.Pane_id.t ->
  cwd:string ->
  argv:string list ->
  env:string list ->
  t

val listen : t -> (event -> unit) -> unit
val pid : t -> int
val buffer : t -> Luv.Buffer.t
val position : t -> int
val oldest : t -> int option
val alive : t -> bool
val scan : t -> bool
val iter_from : t -> int -> (record -> bool) -> unit
val resize : t -> Protocol.size -> unit

val input :
  t ->
  Protocol.Request.input ->
  ((Protocol.paste_result option, string) result -> unit) ->
  (unit, string) result

val snapshot :
  t ->
  history:Protocol.history ->
  consume:(record -> unit) ->
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
val finished : t -> bool
val kill : t -> unit
