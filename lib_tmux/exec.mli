val look_path : path:string -> string -> string option
val invoked_path : path:string -> string -> string
val candidates : string -> string list
val resolve_binary : kido_tmux:string option -> path:string -> string -> string
val binary : string Lazy.t
val write_all : Unix.file_descr -> string -> unit
val spawn : string list -> (int * Unix.file_descr * Unix.file_descr, string) result
val exec : ?stdin:string -> string list -> (string, string) result
val run : ?stdin:string -> string list -> string
val global_option : string -> string
val list_panes : unit -> Pane.t list
val capture_pane : string -> string list
val capture_screen : string -> string

type client_state = { session : string; focused : bool }

val current_client : unit -> string
val client_format : string
val parse_client_state : string list -> string -> client_state option
val client_state : string -> client_state option
val real_clients : string list -> string list
val resolve_client : pane:string -> tmux_env:string -> string option
val switch_session : client:string -> next:bool -> unit
val switch_window : client:string -> next:bool -> unit
val jump : client:string -> string -> unit
val release_side_focus : string -> unit
val send_prompt : string -> string -> unit
val window_exists : string -> bool

type window = { window_id : string; pane_id : string; pane_pid : int }

val new_window_args :
  session:string -> name:string -> cwd:string -> env:string list -> string list -> string list

val new_window :
  session:string -> name:string -> cwd:string -> env:string list -> string list -> window

val kill_window : string -> unit
val kill_pane : string -> unit
val mark_run : string -> string -> unit
