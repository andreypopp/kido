val optional_id_to_yojson : Tmux.Pane.id option -> Yojson.Safe.t
val optional_id_of_yojson : Yojson.Safe.t -> (Tmux.Pane.id option, string) result

type exit = { code : int; at : float }

type t = {
  session_name : string;
  session_id : Tmux.Session.id;
  session_created : float;
  window_index : int;
  window_id : Tmux.Window.id;
  window_name : string;
  window_layout : string;
  pane_id : Tmux.Pane.id;
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

val list_panes : ?socket:string -> ?conn:Tmux.Conn.t -> unit -> (t list, string) result
val resolve_client : pane:Tmux.Pane.id option -> tmux_env:string -> string option
val mark_ssh : Tmux.Pane.id -> string -> (unit, string) result
val mark_run : Tmux.Pane.id -> string -> (unit, string) result
val shell : t -> shell
val find : t list -> Tmux.Pane.id -> t option

type session = { name : string; id : Tmux.Session.id; windows : t list list }

val order_sessions : t list -> session list
val window_focused : t list -> Tmux.Window.id -> bool
val last_window : t list -> Tmux.Window.id -> bool
val last_pane : t list -> Tmux.Window.id -> bool
val run_pane : t list -> Tmux.Window.id -> t option
val active_pane : t list -> string -> Tmux.Pane.id option
