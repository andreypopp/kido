type pane_result = No_pane | Killed | Already_gone | Refused of string
type error = No_run of string | Ended of string

val stop :
  dir:string ->
  wait:float ->
  escalation:float ->
  result:Run.result ->
  Run.id ->
  (pane_result, error) result
