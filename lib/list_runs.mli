type status = Tmux.Program_status.state option

type agent_info = {
  id : Run.id;
  name : string;
  named : bool;
  pane : Tmux.pane_id;
  window : Tmux.window_id;
  status : status;
  activity : string;
  parent : Run.id option;
  depth : int;
  self : bool;
  cwd : string;
  can_message : bool;
  can_reply : bool;
  model : string;
  since_report : int;
  stalled : bool;
}
[@@deriving yojson_of]

val agents :
  dir:string ->
  threshold:float ->
  self:Tmux.pane_id option ->
  caller:Run.id option ->
  session:Tmux.session_id option ->
  state:State.t ->
  (agent_info list, string) result

type row [@@deriving yojson_of]

val list_runs :
  dir:string ->
  threshold:float ->
  self:Tmux.pane_id option ->
  caller:Run.id option ->
  session:Tmux.session_id option ->
  state:State.t ->
  (row list, string) result
