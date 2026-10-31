type t

type event =
  | Title of string
  | Pwd of string
  | Dead of Protocol.dead
  | Failed of Protocol.dead
  | Output

val create :
  Config.t ->
  id:Ids.Pane_id.t ->
  cwd:string ->
  command:string list ->
  env:string list ->
  notify:(t -> event -> unit) ->
  t

val id : t -> Ids.Pane_id.t
val proc : t -> Pane_proc.t
val row : t -> Protocol.row
val offset : t -> int
val sizer : t -> Ids.Client_id.t option
val resize : t -> Protocol.size -> unit
val claim : t -> client:Ids.Client_id.t -> size:Protocol.size -> unit
val shutdown : t -> unit
val kill : t -> unit
