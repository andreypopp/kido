val stop_escalation : unit -> float
(** Seconds a stop waits for its target to go before killing its pane, from KIDO_STOP_ESCALATION_MS
    (default 5s). *)

val interrupt : dir:string -> self:Tmux.pane_id option -> string -> (string, string) result

val stop :
  dir:string ->
  self:Tmux.pane_id option ->
  escalation:float ->
  warn:(string -> unit) ->
  force:bool ->
  string ->
  (string, string) result
(** The line naming how the target stopped. [warn] reports a notice to the parent that could not be
    sent. *)
