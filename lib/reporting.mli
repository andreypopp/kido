val agent_status :
  dir:string ->
  pane:Tmux.pane_id option ->
  id:Run.id ->
  session_file:string ->
  inbox:string ->
  activity:string ->
  model:string ->
  name:string ->
  (unit, Run.pi) result
(** Claims run [id] for the calling pi and marks its pane. [Error] is another live process holding
    the run. *)

val one_line : string -> max:int -> string
