val window_focused : panes:Tmux.Pane.t list Lazy.t -> string -> int

val switch :
  (client:string -> next:bool -> unit) -> client:string -> side_client:string -> next:bool -> int

val stop_escalation : unit -> float
(** Seconds a stop waits for its target to go before killing its pane, from KIDO_STOP_ESCALATION_MS
    (default 5s). *)

val stopped_text : string
val interrupt : dir:string -> self:string -> panes:Tmux.Pane.t list Lazy.t -> string -> int

val stop :
  dir:string ->
  self:string ->
  list_panes:(unit -> Tmux.Pane.t list) ->
  ops:Reap.ops ->
  escalation:float ->
  force:bool ->
  string ->
  int
