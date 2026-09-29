type exit = { code : int; at : float }

type t = {
  session_name : string;
  session_id : string;
  session_created : float;
  window_index : int;
  window_id : string;
  window_name : string;
  window_layout : string;
  pane_id : string;
  active : bool;
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
  session_attached : bool;
  title : string;
}

type shell = Unintegrated | Idle | Running

val shell : t -> shell
val run_option : string
val sep : string
val format : string
val fields : int
val parse : string list -> t list
val find : t list -> string -> t option
val is_window_id : string -> bool

type session = { name : string; id : string; windows : t list list }

val order_sessions : t list -> session list
val watched : t -> bool
val window_focused : t list -> string -> bool
val last_window : t list -> string -> bool
val last_pane : t list -> string -> bool
val run_pane : t list -> string -> t option
val active_pane : t list -> string -> string option
