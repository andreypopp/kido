val max_name_len : int
val check_name : string -> (unit, string) result

type created = { meta : Run.meta; window : Tmux.window_id; pane : Tmux.pane_id; output : string }
type error = Refused_name of string | Failed of string

val create :
  ?env:string list ->
  dir:string ->
  Run.meta ->
  session:Tmux.session_id ->
  string list ->
  (created, string) result

val start :
  ?parent:Run.parent ->
  kind:Run.kind ->
  dir:string ->
  name:string ->
  cwd:string ->
  session:Tmux.session_id ->
  env:string list ->
  string list ->
  (created, error) result

val resolve_parent : dir:string -> state:State.t -> string -> (Run.parent option, string) result
