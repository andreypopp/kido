type pane_id [@@deriving compare, equal, string, yojson]

module Pane_map : Map.S with type key = pane_id

type window_id [@@deriving equal, string, yojson_of]
type session_id [@@deriving equal, string, yojson_of]

module Program_status : sig
  type kind

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

  type t = { serial : int; records : record list } [@@deriving yojson_of]

  val root : t -> record option
  val parse : string -> (t, string) result
  val progress : record -> int option
  val app : t -> record -> string option
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
val list_clients : t -> format:string -> (string list, string) result

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
