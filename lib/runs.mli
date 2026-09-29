val runs : dir:string -> json:bool -> string list -> int

val run_outcome :
  dir:string ->
  capture:(string -> string option) ->
  result:string ->
  text:string ->
  unreported:bool ->
  string ->
  int
