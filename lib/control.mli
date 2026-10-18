val interrupt :
  dir:string ->
  self:Tmux.pane_id option ->
  caller:(Run.id * Run.pi) option ->
  string ->
  (string, string) result

type stopped =
  | Run_stopped of { label : string; result : Run_stop.t }
  | Agent_stopped of { name : string }
  | Agent_killed of { name : string; why : string option; pane : Run_stop.pane_result }

val stop :
  dir:string ->
  self:Tmux.pane_id option ->
  caller:(Run.id * Run.pi) option ->
  escalation:float ->
  warn:(string -> unit) ->
  force:bool ->
  string ->
  (stopped, string) result
(** [warn] reports a notice to the parent that could not be sent. *)
