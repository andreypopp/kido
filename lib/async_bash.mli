val command_argv : string list -> string list
val derived_name : string list -> string

val async_bash :
  dir:string ->
  self:string ->
  exe:string ->
  panes:(Tmux.Pane.t list, string) result Lazy.t ->
  tmux:Spawn_subagent.tmux ->
  name:string ->
  stream:bool ->
  string list ->
  (string, string) result
(** Starts the run and returns its created line. *)
