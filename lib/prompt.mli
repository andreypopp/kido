val deliver_or_paste :
  paste:(string -> string -> unit) ->
  inbox:string ->
  payload:string ->
  pane:string ->
  string ->
  [ `Inbox | `Pasted ]
(** Pastes [text] into [pane] only when the inbox is [Unavailable]: any other failure may have
    delivered already. *)

val agent_panes_in :
  Tmux.Pane.t list ->
  (string * State.session) State.Panes.t ->
  pi:Procs.Int_set.t ->
  Tmux.Pane.t ->
  whole_session:bool ->
  Tmux.Pane.t list

val prompt : dir:string -> self:string -> window:bool -> string -> int
