type pane_result = No_pane | Killed | Already_gone | Refused of string
type error = No_run of string | Ended of string
type mode = Record_and_stop | Record_only | Cleanup [@@deriving equal]

val stop :
  dir:string ->
  wait:float ->
  escalation:float ->
  result:Run.result ->
  ?text:string ->
  mode:mode ->
  Run.id ->
  (pane_result, error) result
