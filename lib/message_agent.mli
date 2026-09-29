type recipient = Named of string | Descendant of string | Parent of string
type spec = { kind : Msg.kind; recipient : recipient; reply_to : string; id : string }

val resolve_target :
  (string * State.session) list ->
  Tmux.Pane.t list ->
  self:string ->
  string ->
  string * State.session

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
  [ `Inbox | `Pasted ]

val send :
  dir:string ->
  self:string ->
  panes:Tmux.Pane.t list Lazy.t ->
  paste:(string -> string -> unit) ->
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
