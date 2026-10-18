val wait : dir:string -> Run.id -> (Run.outcome, string) result
(** Blocks until the run has ended, polling at the sidebar's tick. *)
