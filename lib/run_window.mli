val max_name_len : int
val check_name : string -> (unit, string) result

val create :
  ?resume:bool ->
  dir:string ->
  Run.meta ->
  session:Tmux.session_id ->
  string list ->
  (string, string) result
(** The created line: window, pane and run ids, and a bash run's output file. *)
