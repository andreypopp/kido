val usage : string
val command_argv : string list -> string list
val derived_name : string list -> string

val async_bash :
  dir:string ->
  self:string ->
  exe:string ->
  panes:Tmux.Pane.t list Lazy.t ->
  tmux:Spawn_subagent.tmux ->
  name:string ->
  stream:bool ->
  string list ->
  string
(** Starts the run and returns its created line. *)
