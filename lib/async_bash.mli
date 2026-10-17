val async_bash :
  dir:string ->
  self:Tmux.pane_id option ->
  caller:Run.id option ->
  exe:string ->
  name:string ->
  stream:bool ->
  string * string list ->
  (string, string) result
(** Starts the run and returns its created line. *)
