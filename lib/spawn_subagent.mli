type flags = {
  name : string;
  task_file : string;
  model : string;
  tools : string option;
  resume : string;
  fork : string;
  no_parent : bool;
  command : string list;
}

type request
type error = Usage of string | Invalid of string

val parse : flags -> (request, error) result

val spawn :
  dir:string ->
  self:Tmux.pane_id option ->
  caller:(Run.id * Run.pi) option ->
  path:string ->
  request ->
  (Run_window.created, string) result
