val inbox_path : dir:string -> string -> string
val v1 : int

type kind = Message | Ask | Reply | Notice | Stream | Steer | Interrupt | Stop | Other of string

val string_of_kind : kind -> string
val kind_of_string : string -> kind

type from = { session : string; name : string; pane : string } [@@deriving yojson]

type envelope = {
  v : int;
  kind : kind;
  id : string;
  from : from;
  reply_to : string;
  text : string;
  run : string;
  output : string;
}
[@@deriving yojson]

val parse : string -> envelope option
(** [parse raw] is [Some env] when [raw] is a JSON object carrying both "v" and "kind"; anything
    else, including a JSON object missing either key, is v0 raw prompt text. *)

val new_id : unit -> string

(** An outcome a caller branches on: [Unavailable] is the only case a send-keys paste may fall back
    on, because nothing has been sent yet. [Refused] and [Failed] mean the message may already have
    arrived. *)
type error = Unavailable of string | Refused of string | Failed of string

val inbox_timeout : float ref
(** Bounds the whole exchange, connect included. A ref so a test can shorten it. *)

val deliver : path:string -> string -> (unit, error) result
val send : id:string -> State.session -> envelope -> (unit, error) result
val notify : dir:string -> parent_session:string -> from:from -> string -> (unit, error) result
