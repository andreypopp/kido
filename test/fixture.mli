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

val pane :
  ?session:string ->
  ?created:float ->
  ?session_id:string ->
  ?index:int ->
  ?window:string ->
  ?active:bool ->
  ?attached:bool ->
  ?running:bool ->
  ?start:float ->
  ?prompt:float ->
  ?run:string ->
  ?pid:int ->
  ?cmd:string ->
  ?cwd:string ->
  ?title:string ->
  string ->
  Tmux.Pane.t

val start_inbox : reply:string -> string * (unit -> string list)
(** A fake agent inbox: accepts one connection at a time, reads it to EOF, answers with [reply]
    (empty meaning "never answer"), and returns its path and what arrived so far. *)
