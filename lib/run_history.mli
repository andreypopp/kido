type info = { meta : Run.meta; outcome : Run.outcome option } [@@deriving yojson_of]

val list : ?owner:Run.id -> dir:string -> unit -> info list
(** Newest first. *)

type detail = { info : info; task : string; screen : string option; report : string option }

val detail : dir:string -> Run.id -> (detail, string) result
