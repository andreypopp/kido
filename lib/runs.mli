type info = { meta : Subrun.meta; outcome : Subrun.outcome option } [@@deriving yojson_of]

val list : ?parent_session:string -> dir:string -> unit -> info list
(** Newest first. *)

val table : now:Timestamp.t -> info list -> string list list
(** The header row, then one row per run. *)

val show : dir:string -> json:bool -> string -> (string, string) result
(** The whole text of [kido runs <run-id>]. *)

val run_outcome :
  dir:string ->
  warn:(string -> unit) ->
  result:Subrun.result ->
  text:string ->
  unreported:bool ->
  string ->
  (unit, string) result
