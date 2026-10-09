val debug_log : dir:string -> string

val hook : dir:string -> pane:Tmux.Pane.id option -> debug:bool -> string -> (unit, string) result
(** Records the hook event JSON [text]. *)

val agent_status :
  dir:string ->
  pane:Tmux.Pane.id option ->
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
