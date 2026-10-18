type pane_result = No_pane | Killed | Already_gone | Refused of string
type t = { ending : Run_ending.ending option; pane : pane_result }
type error = No_run of string | Ended of string | Pi of string

val wait_until : within:float -> (unit -> bool) -> bool
val close_pane : dir:string -> ?before:(unit -> unit) -> Tmux.pane_id option -> pane_result

val stop :
  dir:string ->
  wait:float ->
  escalation:float ->
  result:Run.result ->
  ?text:string ->
  Run.id ->
  (t, error) result
