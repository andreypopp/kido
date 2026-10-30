val send :
  Pane.t ->
  Protocol.input ->
  ((Protocol.pasted option, string) result -> unit) ->
  (unit, string) result
