val getenv : string -> string
val is_file : string -> bool
val is_executable : string -> bool
val look_path : path:string -> string -> string option
val invoked_path : path:string -> string -> string
val candidates : string -> string list
val abs : string -> string

val self : string Lazy.t
(** This executable as invoked ({!invoked_path} of [argv.(0)] on [$PATH]), unresolved. *)

val binary : string Lazy.t
val write_all : Unix.file_descr -> string -> unit

type process = { pid : int; stdin : Unix.file_descr; stdout : Unix.file_descr }

val spawn : string list -> (process, string) result
val global_option : string -> string
val list_panes : unit -> (Pane.t list, string) result
val capture_pane : string -> (string list, string) result
val capture_screen : string -> (string, string) result

type client_state = { session : string; focused : bool }

val current_client : unit -> string
val client_format : string
val parse_client_state : string list -> string -> client_state option
val client_state : string -> client_state option
val resolve_client : pane:string -> tmux_env:string -> string option
val switch_session : client:string -> next:bool -> (unit, string) result
val switch_window : client:string -> next:bool -> Pane.t list list -> (unit, string) result
val jump : client:string -> string -> (unit, string) result
val release_side_focus : string -> (unit, string) result
val send_prompt : string -> string -> (unit, string) result
val window_exists : string -> bool

type window = { window_id : string; pane_id : string; pane_pid : int }

val new_window :
  session:string ->
  name:string ->
  cwd:string ->
  env:string list ->
  string list ->
  (window, string) result

val kill_window : string -> (unit, string) result
val kill_pane : string -> (unit, string) result
val mark_run : string -> string -> (unit, string) result
