type info = {
  meta : Run.meta;
  outcome : Run.outcome option;
  session : string option;
  output : string;
}
[@@deriving yojson_of]

val list : ?parent:Run.parent -> dir:string -> state:State.t -> unit -> info list
(** Newest first. *)

type detail = { info : info; screen : string option }

val detail : dir:string -> state:State.t -> Run.id -> (detail, string) result
