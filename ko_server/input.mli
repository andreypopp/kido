val send :
  Pane.t ->
  Protocol.Request.input ->
  ((Protocol.paste_result option, string) result -> unit) ->
  (unit, string) result
