type info = { meta : Run.meta; outcome : Run.outcome option } [@@deriving yojson_of]

val list : ?owner:Run.id -> dir:string -> unit -> info list
(** Newest first. *)

type detail = { info : info; task : string; screen : string option; report : string option }

val detail : dir:string -> Run.id -> (detail, string) result

val run_outcome :
  dir:string ->
  warn:(string -> unit) ->
  result:Run.result ->
  text:string ->
  unreported:bool ->
  Run.id ->
  (unit, string) result
