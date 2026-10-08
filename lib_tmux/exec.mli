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
val argv : string -> string list -> string array
val write_all : Unix.file_descr -> string -> unit

type process = { pid : int; stdin : Unix.file_descr; stdout : Unix.file_descr }

val spawn : ?socket:string -> string list -> (process, string) result
val global_option : string -> string
val list_panes : ?socket:string -> unit -> (Pane.t list, string) result

val panes_and_programs :
  ?socket:string -> unit -> (Pane.t list * Program_status.t Pane.Map.t, string) result

val capture_pane : ?socket:string -> Pane.id -> (string list, string) result
val capture_screen : ?socket:string -> Pane.id -> (string, string) result

type client_state = { session : string; session_id : Session.id; focused : bool }

val current_client : unit -> string
val client_format : string
val parse_client_state : string list -> string -> client_state option
val client_state : ?socket:string -> string -> client_state option
val resolve_client : pane:Pane.id option -> tmux_env:string -> string option

val switch_session :
  socket:string option ->
  client:string ->
  next:bool ->
  ((Session.id * Window.id) option, string) result

val window_target :
  next:bool -> window:Window.id -> (Pane.t list * Pane.id option) list -> Pane.t option

val switch_window :
  ?socket:string ->
  client:string ->
  next:bool ->
  (Pane.t list * Pane.id option) list ->
  ((Session.id * Window.id) option, string) result

val jump :
  ?socket:string ->
  client:string ->
  session:Session.id ->
  window:Window.id ->
  Pane.id ->
  (unit, string) result

val release_side_focus : ?socket:string -> string -> (unit, string) result
val send_prompt : Pane.id -> string -> (unit, string) result
val window_exists : ?socket:string -> Window.id -> bool

type window = { window_id : Window.id; pane_id : Pane.id; pane_pid : int }

val new_window :
  ?socket:string ->
  ?remain_on_exit:bool ->
  session:Session.id ->
  name:string ->
  cwd:string ->
  env:string list ->
  string list ->
  (window, string) result

val new_shell :
  socket:string option ->
  [ `Window of Window.id | `Session of Session.id ] ->
  (Session.id * Window.id * Pane.id, string) result

val kill_window : ?socket:string -> Window.id -> (unit, string) result
val kill_pane : ?socket:string -> Pane.id -> (unit, string) result
val mark_run : Pane.id -> string -> (unit, string) result
