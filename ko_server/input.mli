val send :
  Pane.t ->
  Protocol.input ->
  ((Protocol.paste_result option, string) result -> unit) ->
  (unit, string) result
