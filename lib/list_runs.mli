type status = Tmux.Program_status.state option

type agent_info = {
  id : string;
  name : string;
  named : bool;
  pane : Tmux.pane_id;
  window : Tmux.window_id;
  status : status;
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
[@@deriving yojson_of]

val caller_pane : Tmux_pane.t list -> Tmux.pane_id option -> (Tmux_pane.t, string) result

val in_session :
  Tmux_pane.t list -> (string * Run.pi) list -> Tmux.session_id -> (string * Run.pi) list

val agents :
  dir:string ->
  threshold:float ->
  self:Tmux.pane_id option ->
  caller:Run.id option ->
  session:Tmux.session_id option ->
  panes:Tmux_pane.t list ->
  (agent_info list, string) result

type row [@@deriving yojson_of]

val list_runs :
  dir:string ->
  threshold:float ->
  self:Tmux.pane_id option ->
  caller:Run.id option ->
  session:Tmux.session_id option ->
  panes:Tmux_pane.t list ->
  (row list, string) result
