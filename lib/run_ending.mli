val quote : string -> string
(** A Go [%q]-style double-quoted string: control bytes escaped, non-ASCII kept. *)

type detail = Bash | Streamed of { unstreamed : int } | Agent of { unreported : bool }
type ending = { meta : Run.meta; outcome : Run.outcome; detail : detail }

val send : dir:string -> ending -> (unit, Msg.error) result

val stop_result : dir:string -> Run.meta -> Run.result
(** The ending a deliberate stop records: [Completed] for an agent that reported, [Stopped]
    otherwise. *)

val record_ending : dir:string -> Run.meta -> Run.outcome -> ending option
(** Writes the outcome and returns the ending when this writer won the write. *)

val run_outcome :
  dir:string ->
  warn:(string -> unit) ->
  result:Run.result ->
  text:string ->
  Run.id ->
  (unit, string) result
