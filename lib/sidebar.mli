module String_map = State.String_map

type options = { interval : float; client : string; dir : string; threshold : float; grace : float }
type lingering = { name : string; parent : string; outcome : Subrun.result option }
type probe = { reported : float; read : float; dismissed : bool }

type snapshot = {
  current : string;
  active : string;
  focused : bool;
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

type line =
  | Header of { id : string; name : string; current : bool }
  | Row of row
  | Message of string

type phase = { running : bool; since : float; drawn : bool; held : Tmux.Pane.exit option }

type model = {
  opts : options;
  snap : snapshot;
  lines : line array;
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

val switch_window : dir:string -> client:string -> next:bool -> (unit, string) result
val rebuild : model -> model
val poll : ?wait:bool -> opts:options -> Tmux.Conn.t -> snapshot -> snapshot
val step : model -> snapshot -> model * bool
val client_json : model -> Yojson.Safe.t option
val to_json : client:Yojson.Safe.t -> model -> Yojson.Safe.t
