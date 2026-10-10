type recipient =
  | Named of string
  | Descendant of string
  | Descendant_run of Subrun.id
  | Parent of string

type spec = { kind : Msg.kind; reply_to : string; id : string }
type failure = Unavailable of string | Failed of string
type send_error = No_text | Not_sent of string

val reaches :
  (string * State.session) list ->
  Tmux_pane.t list ->
  self:Tmux.Pane.id option ->
  string ->
  (bool, string) result
(** Whether session [id] is the caller's own or its descendant, over a per-pane list; a caller that
    is no agent reaches everything. *)

val resolve :
  live:(string * State.session) list ->
  panes:Tmux_pane.t list ->
  self:Tmux.Pane.id option ->
  recipient ->
  (string * State.session, string) result

val deliver :
  states:(string * State.session) Tmux.Pane.Map.t ->
  panes:Tmux_pane.t list ->
  self:Tmux.Pane.id option ->
  spec ->
  State.session ->
  string ->
  ([ `Inbox | `Pasted ], failure) result

val send :
  dir:string ->
  self:Tmux.Pane.id option ->
  recipient ->
  spec ->
  string ->
  (string, send_error) result
(** The line naming how it was delivered. *)

val notify_parent :
  dir:string ->
  self:Tmux.Pane.id option ->
  warn:(string -> unit) ->
  parent:string ->
  run:string ->
  string ->
  (string, send_error) result
