val agent_status :
  dir:string ->
  pane:Tmux.pane_id option ->
  agent:string ->
  session:string ->
  inbox:string ->
  activity:string ->
  parent_pid:int ->
  parent_session:string ->
  depth:int ->
  model:string ->
  name:string ->
  (unit, State.session) result
(** [Error] is another live process holding the session. *)

val one_line : string -> max:int -> string
