val inbox_path : dir:string -> string -> (string, string) result
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
val new_id : unit -> string

type error = Unavailable of string | Refused of string | Failed of string

val string_of_error : error -> string
val deliver : ?timeout:float -> path:string -> string -> (unit, error) result
val send : id:string -> State.session -> envelope -> (unit, error) result
val notify : dir:string -> parent_session:string -> from:from -> string -> (unit, error) result
