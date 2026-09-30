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

val caller_pane : Tmux.Pane.t list -> string -> (Tmux.Pane.t, string) result
val agent_title : string -> string
val display_name : Tmux.Pane.t list -> State.session -> string
val per_pane : (string * State.session) list -> (string * State.session) list

val in_session :
  Tmux.Pane.t list -> (string * State.session) list -> string -> (string * State.session) list

val parent_edge : string * State.session -> string option
val is_ancestor : (string * string) list -> ancestor:string -> string -> bool

val list_agents :
  dir:string -> threshold:float -> self:string -> session:string -> (agent_info list, string) result

val table : agent_info list -> string list list
(** The header row, then one row per agent. *)
