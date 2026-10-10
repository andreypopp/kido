type info = { meta : Subrun.meta; outcome : Subrun.outcome option } [@@deriving yojson_of]

val list : ?parent_session:string -> dir:string -> unit -> info list
(** Newest first. *)

type detail = { info : info; task : string; screen : string option; report : string option }

val detail : dir:string -> string -> (detail, string) result

val run_outcome :
  dir:string ->
  warn:(string -> unit) ->
  result:Subrun.result ->
  text:string ->
  unreported:bool ->
  string ->
  (unit, string) result
