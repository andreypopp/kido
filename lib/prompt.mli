val not_accepting : name:string -> run:string option -> string

val deliver_or_paste :
  inbox:string ->
  payload:string ->
  pane:Tmux.Pane.id option ->
  name:string ->
  run:string option ->
  string ->
  ([ `Inbox | `Pasted ], string) result

type error = No_prompt | Not_found | Several | Failed of string

val prompt : dir:string -> self:Tmux.Pane.id option -> window:bool -> string -> (unit, error) result
