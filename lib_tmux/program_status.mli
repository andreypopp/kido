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
