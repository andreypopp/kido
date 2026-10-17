type recipient =
  | Named of string
  | Descendant of string
  | Descendant_run of Run.id
  | Parent of Run.id

type spec = Message | Reply of string | Ask of string option | Notice | Steer | Interrupt | Stop
type failure = Unavailable of string | Failed of string
type send_error = No_text | Not_sent of string

val reaches : dir:string -> caller:Run.id option -> Run.id -> bool
(** Whether run [id] is the caller's own or its descendant; a caller that is no agent reaches
    everything. *)

val resolve :
  dir:string ->
  state:State.t ->
  self:Tmux.pane_id option ->
  caller:(Run.id * Run.pi) option ->
  recipient ->
  (Run.id * Run.pi, string) result

val deliver :
  dir:string ->
  caller:(Run.id * Run.pi) option ->
  state:State.t ->
  self:Tmux.pane_id option ->
  spec ->
  Run.id * Run.pi ->
  string ->
  ([ `Inbox | `Pasted ], failure) result

val send :
  dir:string ->
  self:Tmux.pane_id option ->
  caller:(Run.id * Run.pi) option ->
  recipient ->
  spec ->
  string ->
  (string, send_error) result
(** The line naming how it was delivered. *)

val notify_parent :
  dir:string ->
  self:Tmux.pane_id option ->
  caller:(Run.id * Run.pi) option ->
  warn:(string -> unit) ->
  parent:Run.id option ->
  run:Run.id option ->
  status:bool ->
  string ->
  (string, send_error) result
(** [status] states that the notice is the child's status, not a report of its work. Such a notice
    writes no report file and carries no parent guidance. *)
