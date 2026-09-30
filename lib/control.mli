val stop_escalation : unit -> float
(** Seconds a stop waits for its target to go before killing its pane, from KIDO_STOP_ESCALATION_MS
    (default 5s). *)

val interrupt :
  dir:string ->
  self:string ->
  panes:(Tmux.Pane.t list, string) result Lazy.t ->
  string ->
  (string, string) result

val stop :
  dir:string ->
  self:string ->
  list_panes:(unit -> (Tmux.Pane.t list, string) result) ->
  ops:Reap.ops ->
  escalation:float ->
  warn:(string -> unit) ->
  force:bool ->
  string ->
  (string, string) result
(** The line naming how the target stopped. [warn] reports a notice to the parent that could not be
    sent. *)
