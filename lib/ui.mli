(** The sidebar: sessions and their panes, with agent panes badged by the status the agent reported.
    Every [Tmux.Conn] call happens inside the one tick [Cmd.perform]; update and view spawn tmux
    commands through [Tmux.Exec] only. *)

module Panes = State.Panes
module Runs : Map.S with type key = string
module Style = Mosaic.Ansi.Style

type options = {
  interval : float;
  client : string;
  standalone : bool;
      (** One-shot picker: q, Esc and C-c quit, and picking a pane jumps and quits. *)
  dir : string;
  threshold : float;
  grace : float;
}

type lingering = { name : string; parent : string; outcome : Subrun.result option }
type probe = { reported : float; read : float; dismissed : bool }

type snapshot = {
  current : string;
  active : string;
  focused : bool;
  panes : Tmux.Pane.t list;
  states : (string * State.session) Panes.t;
  ssh : Procs.ssh_session Procs.Int_map.t;
  pi : Procs.Int_set.t;
  probed : float;
  wake : float option;
  err : string option;
  probes : probe Panes.t;
  lingering : lingering Runs.t;
}

val empty : snapshot
val shell_run_delay : float
val shell_run_hold : float

val lingering_subagents :
  dir:string ->
  Tmux.Pane.t list ->
  (string * State.session) Panes.t ->
  lingering Runs.t ->
  lingering Runs.t

val same : snapshot -> snapshot -> bool

type span = Mosaic.span = { text : string; style : Style.t }
type row = { spans : span list; pane_id : string option }
type phase = { running : bool; since : float; drawn : bool; held : Tmux.Pane.exit option }

type model = {
  opts : options;
  conn : Tmux.Conn.t option;
  snap : snapshot;
  rows : row array;
  cursor : int;
  top : int;
  width : int;
  height : int;
  status : string;
  filter : string;
  searching : bool;
  g_pend : bool;
  started : float;
  seen : float Panes.t;
  phases : phase Panes.t;
  ssh_remote : string list;
  now : unit -> float;
  at : float;
  clock : State.reading;
}

val make : ?conn:Tmux.Conn.t -> now:(unit -> float) -> options -> model
val interactive_pane : model -> Tmux.Pane.t -> bool
val ssh_remote : model -> Tmux.Pane.t -> bool
val shell_outcome : model -> Tmux.Pane.t -> Tmux.Pane.exit option
val track : model -> model
val shell_pending : model -> bool

type indicator =
  | Status of State.status
  | Unknown
  | Done
  | Failed
  | Stalled
  | Gone of Subrun.result option

val indicator : indicator -> span option
val field : span option -> span list
val shell_indicator : model -> phase -> indicator option
val agent_title_of : model -> Tmux.Pane.t -> string option
val pane_label : model -> Tmux.Pane.t -> span list

type placement = { panes : Tmux.Pane.t list; anchor : string option }

val order_windows_by_tree :
  Tmux.Pane.t list list -> (string * State.session) Panes.t -> lingering Runs.t -> placement list

val row_text : row -> string
val rebuild : model -> model

type msg =
  | Snapshot of snapshot
  | Key of Mosaic.Event.key
  | Mouse of Mosaic.Event.mouse
  | Resize of int * int

val update : msg -> model -> model * msg Mosaic.Cmd.t
val parse_duration : string -> (float, string) result
val run : interval:float -> client:string option -> int
