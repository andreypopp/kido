type exit = { code : int; at : float }

type t = {
  panes : pane list;  (** Every pane on the server. *)
  runs : Run.t Tmux.Pane_map.t;  (** Runs, per-pane. *)
  agents : (Run.id * Run.pi) Tmux.Pane_map.t;  (** Runs, which are agents, per-pane. *)
}

and pane = {
  session_name : string;
  session_id : Tmux.session_id;
  session_created : float;
  session_order : int option;
  window_index : int;
  window_id : Tmux.window_id;
  window_name : string;
  window_layout : string;
  pane_id : Tmux.pane_id;
  active : bool;
  pane_active : bool;
  pane_pid : int;
  current_command : string;
  current_path : string;
  alternate_on : bool;
  command_running : bool;
  command_start : float option;
  last_prompt : float option;
  last_exit : exit option;
  command_line : string;
  dead_at : float option;
  run : string option;
  ssh : (string * string) option;
  session_attached : bool;
  modal : bool;
  program_status : Tmux.Program_status.t;
  title : string;
}

type shell = Unintegrated | Idle | Running

val empty : t
val read : dir:string -> Tmux.t -> (t, string) result
val shell : pane -> shell
val find : t -> Tmux.pane_id -> pane option
val caller_pane : t -> Tmux.pane_id option -> (pane, string) result

val display_name : t -> Run.pi -> string
(** The name its pi last reported, else the title of the pane it holds. *)

val find_window_run : t -> Tmux.window_id -> pane option
(** The first pane in the window whose run is an agent, bash or stream run. *)

type session = { name : string; id : Tmux.session_id; windows : pane list list }

val order_sessions : t -> session list
val window_focused : t -> Tmux.window_id -> bool
val last_window : t -> Tmux.window_id -> bool
val last_pane : t -> Tmux.window_id -> bool
val active_pane : t -> string -> Tmux.pane_id option
