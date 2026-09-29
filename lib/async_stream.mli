type knobs = { batch : float; backoff_floor : float; backoff_cap : float }

val knobs : (string -> string option) -> knobs
(** KIDO_STREAM_BATCH_MS, KIDO_STREAM_BACKOFF_MS and KIDO_STREAM_BACKOFF_CAP_MS, from [getenv]. *)

val batch_bytes : int
val pending_max : int
val run_budget : int
val sanitize : string -> string

type t

val start : dir:string -> knobs -> Subrun.meta -> t
(** Starts the sender thread for a run. A parent that cannot be resolved is not an error: every send
    fails and every line counts as unstreamed. *)

val write : t -> string -> unit
(** Never blocks on the parent: takes the lock, appends, returns. *)

val close : t -> int
(** Stops the stream after flushing what is left, a last unterminated line included, and waiting out
    any send in flight, so a notice sent next follows the final chunk. Returns how many of the
    command's lines the parent never acknowledged. *)
