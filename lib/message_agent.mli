type recipient = Named of string | Descendant of string | Parent of string
type spec = { kind : Msg.kind; reply_to : string; id : string }
type failure = Unavailable of string | Failed of string

val resolve_target :
  (string * State.session) list ->
  Tmux.Pane.t list ->
  self:string ->
  string ->
  string * State.session

val reaches : (string * State.session) list -> Tmux.Pane.t list -> self:string -> string -> bool
(** Whether session [id] is the caller's own or its descendant, over a per-pane list; a caller that
    is no agent reaches everything. *)

val resolve :
  live:(string * State.session) list ->
  panes:Tmux.Pane.t list ->
  self:string ->
  recipient ->
  string * State.session

val deliver :
  states:(string * State.session) State.Panes.t ->
  panes:Tmux.Pane.t list ->
  self:string ->
  paste:(string -> string -> unit) ->
  spec ->
  State.session ->
  string ->
  ([ `Inbox | `Pasted ], failure) result
(** A plain message falls back to a paste; any other kind needs the inbox, and its failure is the
    whole sentence to print. [Unavailable] is nothing listening there. *)

val send :
  dir:string ->
  self:string ->
  panes:Tmux.Pane.t list Lazy.t ->
  paste:(string -> string -> unit) ->
  recipient ->
  spec ->
  string ->
  int

val max_report_bytes : int
val head_within : string -> int -> string

val notify_parent :
  dir:string ->
  self:string ->
  panes:Tmux.Pane.t list Lazy.t ->
  paste:(string -> string -> unit) ->
  parent:string ->
  run:string ->
  string ->
  int
