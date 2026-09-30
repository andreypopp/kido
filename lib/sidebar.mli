module String_map = State.String_map

type options = {
  interval : float;
  client : string;
  socket : string option;
  dir : string;
  threshold : float;
  grace : float;
}

val default_interval : float

type lingering = { name : string; parent : string; outcome : Subrun.result option }
type probe = { reported : float; read : float; dismissed : bool }

type snapshot = {
  client : Tmux.Exec.client_state option;
  active : string;
  panes : Tmux.Pane.t list;
  states : (string * State.session) String_map.t;
  ssh : Procs.ssh_session Procs.Int_map.t;
  pi : Procs.Int_set.t;
  probed : float;
  wake : float option;
  err : string option;
  probes : probe String_map.t;
  lingering : lingering String_map.t;
}

val empty : snapshot
val shell_run_delay : float
val shell_run_hold : float

val lingering_subagents :
  dir:string ->
  Tmux.Pane.t list ->
  (string * State.session) String_map.t ->
  lingering String_map.t ->
  lingering String_map.t

val same : snapshot -> snapshot -> bool

type reading = { wall : Timestamp.t; mono : Mtime.t }

val detect_pause : reading -> reading -> bool

type client = { session : string; window : string; pane : string }

type role =
  [ `Plain | `Current | `Proc | `Dim | `Err | `Running | `Waiting | `Compacting | `Done | `Stalled ]

type span = { text : string; role : role }

type indicator =
  | Status of State.status
  | Unknown
  | Done
  | Failed
  | Stalled
  | Gone of Subrun.result option

type row = {
  pane : string;
  window : string;
  tree : string;
  indicator : indicator option;
  title : span list;
  tail : span list;
}

type section = { id : string; name : string; current : bool; rows : row list }
type phase = { running : bool; since : float; drawn : bool; held : Tmux.Pane.exit option }

type model = {
  opts : options;
  snap : snapshot;
  sessions : section list;
  client : client option;
  search : string option;
  started : float;
  seen : float String_map.t;
  phases : phase String_map.t;
  ssh_remote : unit String_map.t;
  now : unit -> float;
  at : float;
  clock : reading;
}

val make : now:(unit -> float) -> options -> model
val interactive_pane : model -> Tmux.Pane.t -> bool
val ssh_remote : model -> Tmux.Pane.t -> bool
val shell_outcome : model -> Tmux.Pane.t -> Tmux.Pane.exit option
val track : model -> model
val shell_pending : model -> bool
val attention : model -> string -> bool
val shell_indicator : model -> phase -> indicator option
val agent_title_of : model -> Tmux.Pane.t -> string option
val pane_label : model -> Tmux.Pane.t -> row

type placement = { panes : Tmux.Pane.t list; anchor : string option }

val order_windows_by_tree :
  Tmux.Pane.t list list ->
  (string * State.session) String_map.t ->
  lingering String_map.t ->
  placement list

val windows_in_order :
  Tmux.Pane.t list ->
  (string * State.session) String_map.t ->
  lingering String_map.t ->
  Tmux.Pane.t list list

val switch_window :
  socket:string option -> dir:string -> client:string -> next:bool -> (unit, string) result

val rebuild : model -> model
val poll : ?wait:bool -> opts:options -> Tmux.Conn.t -> snapshot -> snapshot
val step : model -> snapshot -> model * bool

type command = Filter of string option | Ignored

val command : string -> command
val to_json : model -> Yojson.Safe.t option
