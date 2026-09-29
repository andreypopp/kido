val hook : string list -> int

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
  int

val one_line : string -> max:int -> string
