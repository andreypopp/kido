val max_window_name_len : int

type pi = { path : string; session_dir : string; agent_dir : string; home : string }

type flags = {
  parent_pid : int;
  parent_session : string;
  name : string;
  task_file : string;
  model : string;
  tools : string;
  resume : string;
  fork : string;
  keep_alive : bool;
  no_parent : bool;
  command : string list;
}

type request
type owner = Given of State.parent | Nobody | Adopt

val parse : flags -> (request, string) result
val check_window_name : string -> (unit, string) result

val caller :
  dir:string -> self:string -> owner -> (Tmux.Pane.t * State.parent option * int, string) result
(** The caller's pane, the parent a run it starts gets, and the run's depth. *)

val run_env :
  dir:string -> Subrun.id -> State.parent option -> int -> keep_alive:bool -> string list

val create_run_window :
  dir:string ->
  Subrun.meta ->
  session:string ->
  env:string list ->
  string list ->
  (string, string) result
(** The created line: window, pane and run ids, and a bash run's output file. *)

val spawn : dir:string -> self:string -> pi:pi -> request -> (string, string) result
