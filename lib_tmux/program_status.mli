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

val parse : string -> (t, string) result
val merge : t -> t option -> t
val merge_panes : t Pane.Map.t -> t Pane.Map.t -> t Pane.Map.t
val representative : ?seen:int -> t -> record option
val progress : record -> int option
val app : t -> record -> string option
val to_yojson : t -> Yojson.Safe.t
val prune : current:Pane.id list -> t Pane.Map.t -> t Pane.Map.t
val format : string
val parse_lines : string list -> t Pane.Map.t
