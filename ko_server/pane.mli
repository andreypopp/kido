type t

type event =
  | Title of string
  | Pwd of string
  | Dead of Protocol.dead
  | Failed of Protocol.dead
  | Output

val create :
  Config.t ->
  id:string ->
  cwd:string ->
  command:string list ->
  env:string list ->
  notify:(t -> event -> unit) ->
  t

val id : t -> string
val proc : t -> Pane_proc.t
val row : t -> Protocol.row
val offset : t -> int
val sizer : t -> string option
val resize : t -> Config.size -> unit
val claim : t -> client:string -> size:Config.size -> unit
val shutdown : t -> unit
val kill : t -> unit
