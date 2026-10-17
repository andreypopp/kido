type pane_id [@@deriving compare, equal, string, yojson]
type window_id [@@deriving equal, string, yojson_of]
type session_id [@@deriving equal, string, yojson_of]
type env = { socket : string; session : session_id option }

val env_of_string : string -> env option
(** [$TMUX], [socket,pid,session]; [None] when empty. *)

module Pane_map : Map.S with type key = pane_id

module Program_status : sig
  type kind = Permission | Question | Auth [@@deriving yojson_of]

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

  type t = private { serial : int; records : record list } [@@deriving yojson_of]

  val empty : t
  val root : t -> record option
  val parse : string -> (t, string) result
  val app : t -> record -> string option

  type node = { record : record; depth : int; children : node list }

  val forest : t -> node list
  (** Non-root records under their nearest present ancestor, in path-segment order. *)
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
  val dials : t -> int
end

val safe : string -> string -> (unit, string) result
val binary : string Lazy.t
val argv : string -> string list -> string array
val exec : t -> ?stdin:string -> string list -> (string, string) result
val run : t -> string list -> (unit, string) result
val list_panes : t -> format:string -> (string list, string) result

type client = {
  name : string;
  session : string;
  session_id : session_id;
  focused : bool;
  control : bool;
}

val list_clients : t -> (client list, string) result

val jump :
  t -> client:string -> session:session_id -> window:window_id -> pane_id -> (unit, string) result

val release_side_focus : t -> string -> (unit, string) result

type window = { window_id : window_id; pane_id : pane_id; pane_pid : int }

val new_window :
  t ->
  ?setup:string * (string * string) list ->
  session:session_id ->
  name:string ->
  cwd:string ->
  env:string list ->
  string list ->
  (window, string) result
