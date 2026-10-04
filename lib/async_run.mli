val async_run :
  dir:string ->
  knobs:Async_stream.knobs ->
  warn:(string -> unit) ->
  run_id:string ->
  (int, string) result
(** Tees the command's output to stdout and returns its exit code. [warn] reports a notice to the
    parent that could not be sent. *)
