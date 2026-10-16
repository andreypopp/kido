type recipient =
  | Named of string
  | Descendant of string
  | Descendant_run of Subrun.id
  | Parent of string

type spec = { kind : Msg.kind; reply_to : string; id : string }
type failure = Unavailable of string | Failed of string
type send_error = No_text | Not_sent of string

val reaches : dir:string -> caller:Subrun.id option -> string -> bool
(** Whether run [id] is the caller's own or its descendant; a caller that is no agent reaches
    everything. *)

val resolve :
  dir:string ->
  panes:Tmux_pane.t list ->
  self:Tmux.pane_id option ->
  caller:(Subrun.id * Subrun.pi) option ->
  recipient ->
  (string * Subrun.pi, string) result

val deliver :
  dir:string ->
  caller:(Subrun.id * Subrun.pi) option ->
  panes:Tmux_pane.t list ->
  self:Tmux.pane_id option ->
  spec ->
  string * Subrun.pi ->
  string ->
  ([ `Inbox | `Pasted ], failure) result

val send :
  dir:string ->
  self:Tmux.pane_id option ->
  caller:(Subrun.id * Subrun.pi) option ->
  recipient ->
  spec ->
  string ->
  (string, send_error) result
(** The line naming how it was delivered. *)

val notify_parent :
  dir:string ->
  self:Tmux.pane_id option ->
  caller:(Subrun.id * Subrun.pi) option ->
  warn:(string -> unit) ->
  parent:string ->
  run:string ->
  string ->
  (string, send_error) result
