type created = { meta : Run.meta; window : Tmux.window_id; pane : Tmux.pane_id; output : string }
type error = Refused_name of string | Failed of string

val start :
  ?parent:Run.parent ->
  dir:string ->
  name:string ->
  cwd:string ->
  session:Tmux.session_id ->
  env:string list ->
  string list ->
  (created, error) result

val resolve_parent : dir:string -> state:State.t -> string -> (Run.parent option, string) result
