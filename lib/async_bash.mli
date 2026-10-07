val derived_name : string list -> string

val async_bash :
  dir:string ->
  self:Tmux.Pane.id option ->
  exe:string ->
  name:string ->
  stream:bool ->
  string list ->
  (string, string) result
(** Starts the run and returns its created line. *)
