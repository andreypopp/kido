type info = { meta : Subrun.meta; outcome : Subrun.outcome option }

val info_to_yojson : ?extra:(string * Yojson.Safe.t) list -> info -> Yojson.Safe.t

val list : dir:string -> info list
(** Newest first. *)

val table : now:Timestamp.t -> info list -> string list list
(** The header row, then one row per run. *)

val show : dir:string -> json:bool -> string -> (string, string) result
(** The whole text of [kido runs <run-id>]. *)

val run_outcome :
  dir:string ->
  capture:(string -> string option) ->
  warn:(string -> unit) ->
  result:Subrun.result ->
  text:string ->
  unreported:bool ->
  string ->
  (unit, string) result
