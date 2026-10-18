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

val set_activity : dir:string -> Run.id * Run.pi -> string -> (unit, Run.pi) result
(** Replaces the caller's activity and its @kido_activity, keeping its holder. [Error] is another
    live process holding the run. *)

val unclaim : pane:Tmux.pane_id -> unit
(** Unsets the four options of a pane that is leaving. *)
