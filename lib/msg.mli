val inbox_path : dir:string -> string -> (string, string) result

type kind = Message | Ask | Reply | Notice | Stream | Steer | Interrupt | Stop | Asks

val string_of_kind : kind -> string

type from = { session : string; name : string; pane : Tmux.Pane.id option }

type envelope = {
  kind : kind;
  id : string;
  from : from;
  reply_to : string;
  text : string;
  run : string;
  output : string;
}

val envelope_to_yojson : envelope -> Yojson.Safe.t
val max_notice_bytes : int

val utf_8_prefix : string -> int -> string
(** At most [n] bytes of [s], cut back to a character boundary. *)

val valid_utf_8 : string -> string
(** Each invalid sequence replaced by U+FFFD. *)

val new_id : unit -> string

type error = Unavailable of string | Refused of string | Failed of string

val string_of_error : error -> string
val deliver : ?timeout:float -> path:string -> string -> (unit, error) result
val live_parent : (string * State.session) list -> string -> (State.session, string) result
val notify : dir:string -> parent_session:string -> from:from -> string -> (unit, error) result
