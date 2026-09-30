val hook : string -> (unit, string) result
(** Records the hook event JSON [text]. *)

type status_error =
  | Invalid of string
  | Held of string  (** [Held] is another live process holding the session. *)

val agent_status :
  agent:string ->
  session:string ->
  status:string ->
  title:string ->
  inbox:string ->
  activity:string ->
  parent_pid:int ->
  parent_session:string ->
  depth:int ->
  model:string ->
  ended:bool ->
  remove:bool ->
  string list ->
  (unit, status_error) result

val one_line : string -> max:int -> string
