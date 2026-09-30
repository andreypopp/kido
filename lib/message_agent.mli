type recipient = Named of string | Descendant of string | Parent of string
type spec = { kind : Msg.kind; reply_to : string; id : string }
type failure = Unavailable of string | Failed of string
type send_error = No_text | Not_sent of string

val resolve_target :
  (string * State.session) list ->
  Tmux.Pane.t list ->
  self:string ->
  string ->
  (string * State.session, string) result

val reaches :
  (string * State.session) list ->
  Tmux.Pane.t list ->
  self:string ->
  string ->
  (bool, string) result
(** Whether session [id] is the caller's own or its descendant, over a per-pane list; a caller that
    is no agent reaches everything. *)

val resolve :
  live:(string * State.session) list ->
  panes:Tmux.Pane.t list ->
  self:string ->
  recipient ->
  (string * State.session, string) result

val deliver :
  states:(string * State.session) State.String_map.t ->
  panes:Tmux.Pane.t list ->
  self:string ->
  paste:(string -> string -> (unit, string) result) ->
  spec ->
  State.session ->
  string ->
  ([ `Inbox | `Pasted ], failure) result
(** A plain message falls back to a paste; any other kind needs the inbox, and its failure is the
    whole sentence to print. [Unavailable] is nothing listening there. *)

val send :
  dir:string ->
  self:string ->
  panes:(Tmux.Pane.t list, string) result Lazy.t ->
  paste:(string -> string -> (unit, string) result) ->
  recipient ->
  spec ->
  string ->
  (string, send_error) result
(** The line naming how it was delivered. *)

val notify_parent :
  dir:string ->
  self:string ->
  panes:(Tmux.Pane.t list, string) result Lazy.t ->
  paste:(string -> string -> (unit, string) result) ->
  warn:(string -> unit) ->
  parent:string ->
  run:string ->
  string ->
  (string, send_error) result
