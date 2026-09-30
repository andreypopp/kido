include module type of Tmux_test.Fixture

val dead_pid : unit -> int

val session :
  ?agent:Kido.State.agent ->
  ?pane:string ->
  ?pid:int ->
  ?ts:Kido.Timestamp.t ->
  ?background:bool ->
  ?tool_pending:bool ->
  ?title:string ->
  ?inbox:string ->
  ?parent:string ->
  ?depth:int ->
  Kido.State.status ->
  Kido.State.session

val start_inbox : reply:string -> string * (unit -> string list)
(** A fake agent inbox: accepts one connection at a time, reads it to EOF, answers with [reply]
    (empty meaning "never answer"), and returns its path and what arrived so far. *)

val run :
  dir:string ->
  ?name:string ->
  ?kind:Kido.Subrun.kind ->
  ?parent:string ->
  ?pane:string ->
  ?pid:int ->
  ?cwd:string ->
  ?started_at:float ->
  ?command:string list ->
  string ->
  Kido.Subrun.meta
(** Creates a run under the state directory [dir], with a task and a meta, and a command if given.
*)
