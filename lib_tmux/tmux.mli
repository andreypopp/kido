type pane_id

val pane_id_of_string : string -> pane_id option
val pane_id_to_string : pane_id -> string
val equal_pane_id : pane_id -> pane_id -> bool
val pane_id_to_yojson : pane_id -> Yojson.Safe.t
val pane_id_of_yojson : Yojson.Safe.t -> (pane_id, string) result
val compare_pane_id : pane_id -> pane_id -> int

module Pane_map : Map.S with type key = pane_id

type window_id

val window_id_of_string : string -> window_id option
val window_id_to_string : window_id -> string
val equal_window_id : window_id -> window_id -> bool
val window_id_to_yojson : window_id -> Yojson.Safe.t

type session_id

val session_id_of_string : string -> session_id option
val session_id_to_string : session_id -> string
val equal_session_id : session_id -> session_id -> bool
val session_id_to_yojson : session_id -> Yojson.Safe.t

module Program_status : sig
  type kind = Permission | Question | Auth

  type state =
    | Idle
    | Working of int option
    | Done
    | Blocked of { kind : kind option; progress : int option }
    | Error

  type record = {
    id : string;
    state : state;
    app : string option;
    title : string option;
    msg : string option;
  }

  type t = { serial : int; records : record list }

  val root : t -> record option
  val parse : string -> (t, string) result
  val progress : record -> int option
  val app : t -> record -> string option
  val to_yojson : t -> Yojson.Safe.t
end

type t

val create : ?socket:string -> unit -> t

module Client : sig
  type tmux := t
  type t

  val connect : tmux -> client:string -> t
  val tmux : t -> tmux
  val await_notifications : t -> timeout:float -> unit
  val follow : t -> session_id -> unit
  val close : t -> unit
end

val binary : string Lazy.t
val argv : string -> string list -> string array
val exec : t -> ?stdin:string -> string list -> (string, string) result
val run : t -> string list -> (unit, string) result
val list_panes : t -> format:string -> (string list, string) result

type client_state = { session : string; session_id : session_id; focused : bool }

val client_format : string
val client_state : t -> string -> client_state option
val client_fields : string -> (string * string * session_id * string * string) option

val jump :
  t -> client:string -> session:session_id -> window:window_id -> pane_id -> (unit, string) result

val release_side_focus : t -> string -> (unit, string) result
val window_exists : t -> window_id -> bool

type window = { window_id : window_id; pane_id : pane_id; pane_pid : int }

val new_window :
  t ->
  ?remain_on_exit:bool ->
  session:session_id ->
  name:string ->
  cwd:string ->
  env:string list ->
  string list ->
  (window, string) result
