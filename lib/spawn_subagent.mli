val max_depth : int
val max_task_bytes : int
val max_window_name_len : int
val usage : string

type tmux = {
  new_window :
    session:string ->
    name:string ->
    cwd:string ->
    env:string list ->
    string list ->
    Tmux.Exec.window;
  mark_run : string -> string -> unit;
  window_exists : string -> bool;
  kill_window : string -> unit;
}

val tmux : tmux

type pi = {
  list_models : unit -> (string, string) result;
  session_dir : string;
  agent_dir : string;
  home : string;
}

val list_models : path:string -> unit -> (string, string) result

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

val parse : flags -> request
val check_window_name : string -> unit
val validate_model : (unit -> (string, string) result) -> string list -> unit

val run_env :
  runs:string -> Subrun.id -> State.parent option -> int -> keep_alive:bool -> string list

val create_run_window :
  runs:string -> tmux -> Subrun.meta -> session:string -> env:string list -> string list -> string
(** The created line: window, pane and run ids, and a bash run's output file. *)

val spawn :
  dir:string ->
  self:string ->
  panes:Tmux.Pane.t list Lazy.t ->
  tmux:tmux ->
  pi:pi ->
  request ->
  string
