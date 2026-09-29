type agent_info = {
  id : string;
  name : string;
  agent : State.agent;
  pane : string;
  window : string;
  status : State.status;
  activity : string;
  parent : string;
  depth : int;
  self : bool;
  cwd : string;
  can_message : bool;
  can_reply : bool;
  model : string;
  since_report : int;
  stalled : bool;
}
[@@deriving to_yojson]

val caller_pane : Tmux.Pane.t list -> string -> Tmux.Pane.t
val display_name : Tmux.Pane.t list -> State.session -> string
val per_pane : (string * State.session) list -> (string * State.session) list

val in_session :
  Tmux.Pane.t list -> (string * State.session) list -> string -> (string * State.session) list

val parent_edge : string * State.session -> string option
val is_ancestor : (string * string) list -> ancestor:string -> string -> bool

val build :
  runs:string ->
  threshold:float ->
  wake:Timestamp.t option ->
  now:Timestamp.t ->
  (string * State.session) list ->
  Tmux.Pane.t list ->
  session:string ->
  self:string ->
  agent_info list

val list_agents :
  dir:string ->
  threshold:float ->
  self:string ->
  panes:Tmux.Pane.t list Lazy.t ->
  session:string ->
  json:bool ->
  int
