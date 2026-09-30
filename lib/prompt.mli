val deliver_or_paste :
  paste:(string -> string -> (unit, string) result) ->
  inbox:string ->
  payload:string ->
  pane:string ->
  string ->
  ([ `Inbox | `Pasted ], string) result
(** Pastes [text] into [pane] only when the inbox is [Unavailable]: any other failure may have
    delivered already. *)

val agent_panes_in :
  Tmux.Pane.t list ->
  (string * State.session) State.String_map.t ->
  pi:Procs.Int_set.t ->
  Tmux.Pane.t ->
  whole_session:bool ->
  Tmux.Pane.t list

type error = No_prompt | Not_found | Several | Failed of string

val prompt : dir:string -> self:string -> window:bool -> string -> (unit, error) result
