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
val exec : ?socket:string -> ?stdin:string -> string list -> (string, string) result
val run : ?socket:string -> string list -> (unit, string) result

type client_state = { session : string; session_id : Session.id; focused : bool }

val current_client : unit -> string
val client_format : string
val parse_client_state : string list -> string -> client_state option
val client_state : ?socket:string -> string -> client_state option
val client_fields : string -> (string * string * Session.id * string * string) option

val jump :
  ?socket:string ->
  client:string ->
  session:Session.id ->
  window:Window.id ->
  Pane.id ->
  (unit, string) result

val release_side_focus : ?socket:string -> string -> (unit, string) result
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
