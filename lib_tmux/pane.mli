type id

val of_string : string -> id option
val to_string : id -> string
val equal : id -> id -> bool
val compare : id -> id -> int
val id_to_yojson : id -> Yojson.Safe.t
val id_of_yojson : Yojson.Safe.t -> (id, string) result
val optional_id_to_yojson : id option -> Yojson.Safe.t
val optional_id_of_yojson : Yojson.Safe.t -> (id option, string) result

module Map : Map.S with type key = id

type exit = { code : int; at : float }

type t = {
  session_name : string;
  session_id : Session.id;
  session_created : float;
  window_index : int;
  window_id : Window.id;
  window_name : string;
  window_layout : string;
  pane_id : id;
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
val find : t list -> id -> t option

type session = { name : string; id : Session.id; windows : t list list }

val order_sessions : t list -> session list
val watched : t -> bool
val window_focused : t list -> Window.id -> bool
val last_window : t list -> Window.id -> bool
val last_pane : t list -> Window.id -> bool
val run_pane : t list -> Window.id -> t option
val active_pane : t list -> string -> id option
