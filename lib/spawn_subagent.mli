val max_window_name_len : int

type flags = {
  name : string;
  task_file : string;
  model : string;
  tools : string option;
  resume : string;
  fork : string;
  keep_alive : bool;
  no_parent : bool;
  command : string list;
}

type request
type error = Usage of string | Invalid of string

val parse : flags -> (request, error) result
val check_window_name : string -> (unit, string) result

val create_run_window :
  ?resume:bool ->
  dir:string ->
  Run.meta ->
  session:Tmux.session_id ->
  string list ->
  (string, string) result
(** The created line: window, pane and run ids, and a bash run's output file. *)

val spawn :
  dir:string ->
  self:Tmux.pane_id option ->
  caller:(Run.id * Run.pi) option ->
  path:string ->
  request ->
  (string, string) result
