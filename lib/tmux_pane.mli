type optional_id = Tmux.pane_id option [@@deriving yojson]
type exit = { code : int; at : float }

type t = {
  session_name : string;
  session_id : Tmux.session_id;
  session_created : float;
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
  program_status : Tmux.Program_status.t;
  title : string;
}

type shell = Unintegrated | Idle | Running

val list_panes : Tmux.t -> (t list, string) result

type client_state = { session : string; session_id : Tmux.session_id; focused : bool }

val client_state : Tmux.t -> string -> client_state option
val resolve_client : Tmux.t -> pane:Tmux.pane_id option -> tmux_env:string -> string option
val mark_ssh : Tmux.t -> Tmux.pane_id -> string -> (unit, string) result
val mark_run : Tmux.t -> Tmux.pane_id -> string -> (unit, string) result
val shell : t -> shell
val find : t list -> Tmux.pane_id -> t option

type session = { name : string; id : Tmux.session_id; windows : t list list }

val order_sessions : t list -> session list
val window_focused : t list -> Tmux.window_id -> bool
val last_window : t list -> Tmux.window_id -> bool
val last_pane : t list -> Tmux.window_id -> bool
val run_pane : t list -> Tmux.window_id -> t option
val active_pane : t list -> string -> Tmux.pane_id option
