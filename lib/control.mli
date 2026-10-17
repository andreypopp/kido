val interrupt :
  dir:string ->
  self:Tmux.pane_id option ->
  caller:(Run.id * Run.pi) option ->
  string ->
  (string, string) result

val stop :
  dir:string ->
  self:Tmux.pane_id option ->
  caller:(Run.id * Run.pi) option ->
  escalation:float ->
  warn:(string -> unit) ->
  force:bool ->
  string ->
  (string, string) result
(** The line naming how the target stopped. [warn] reports a notice to the parent that could not be
    sent. *)
