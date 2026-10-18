val wait :
  dir:string ->
  knobs:Async_stream.knobs ->
  notify:bool ->
  warn:(string -> unit) ->
  Run.id ->
  (Run.outcome, string) result
