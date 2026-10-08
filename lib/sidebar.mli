module String_map : Map.S with type key = string

type options = {
  interval : float;
  client : string;
  socket : string option;
  dir : string;
  threshold : float;
  grace : float;
}

val default_interval : float

type lingering = {
  name : string;
  parent : string;
  outcome : Subrun.result option;
  kind : Subrun.kind;
  started : Timestamp.t;
}

type probe = { reported : float; read : float; dismissed : bool }
type ask_target = Live of Tmux.Pane.id | Revivable | Unavailable
type ask = { ask : Ask.t; target : ask_target }

type snapshot = {
  client : Tmux.Exec.client_state option;
  active : Tmux.Pane.id option;
  panes : Tmux.Pane.t list;
  generation : int;
  programs : Tmux.Program_status.t Tmux.Pane.Map.t;
  states : (string * State.session) Tmux.Pane.Map.t;
  ssh : Procs.ssh_session Procs.Int_map.t;
  pi : Procs.Int_set.t;
  probed : float;
  wake : float option;
  err : string option;
  probes : probe Tmux.Pane.Map.t;
  lingering : lingering String_map.t;
  asks : ask list;
}

val empty : snapshot
val shell_run_delay : float
val shell_run_hold : float

val lingering_subagents :
  dir:string -> Tmux.Pane.t list -> lingering String_map.t -> lingering String_map.t

val same : snapshot -> snapshot -> bool

type reading = { wall : Timestamp.t; mono : Mtime.t }

val detect_pause : reading -> reading -> bool

type client = { session : Tmux.Session.id; window : Tmux.Window.id; pane : Tmux.Pane.id }

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

type caption = Text of span list | Elapsed of float
type row_kind = Agent | Run | Ssh | Shell
type run = { kind : Subrun.kind; started : Timestamp.t option }

type row = {
  pane : Tmux.Pane.id;
  window : Tmux.Window.id;
  kind : row_kind;
  indicator : indicator option;
  title : span list;
  caption : caption;
  run : run option;
}

type node = Group of { name : string; first : item; rest : item list } | Item of item
and item = { row : row; children : node list }

type section = { id : Tmux.Session.id; name : string; current : bool; nodes : node list }
type phase = { running : bool; since : float; drawn : bool; held : Tmux.Pane.exit option }

type model = {
  opts : options;
  snap : snapshot;
  sessions : section list;
  client : client option;
  started : float;
  seen : float Tmux.Pane.Map.t;
  program_seen : int Tmux.Pane.Map.t;
  phases : phase Tmux.Pane.Map.t;
  ssh_remote : unit Tmux.Pane.Map.t;
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
val attention : model -> Tmux.Pane.id -> bool
val shell_indicator : model -> phase -> indicator option
val agent_title_of : model -> Tmux.Pane.t -> string option
val pane_label : model -> Tmux.Pane.t -> row

type placement = { panes : Tmux.Pane.t list; anchor : Tmux.Pane.id option }

val order_windows_by_tree :
  Tmux.Pane.t list list ->
  (string * State.session) Tmux.Pane.Map.t ->
  lingering String_map.t ->
  placement list

val windows_in_order :
  Tmux.Pane.t list ->
  (string * State.session) Tmux.Pane.Map.t ->
  lingering String_map.t ->
  (Tmux.Pane.t list * Tmux.Pane.id option) list

val filter : string -> section list -> section list
val rebuild : model -> model
val poll : ?wait:float -> opts:options -> Tmux.Conn.t -> snapshot -> snapshot
val step : model -> snapshot -> model * bool

type direction = Next | Prev
type switched = { session : Tmux.Session.id; window : Tmux.Window.id }

type _ request =
  | Switch_window : direction -> (switched option, string) result request
      (** Switch the client in sidebar order; returns the target, or None when none is eligible. *)
  | Switch_session : direction -> (switched option, string) result request
      (** Switch the client in session order; returns the target, or None with only one session. *)
  | New_window : Tmux.Window.id -> (client, string) result request
      (** Create a shell window in the given session and select it; returns its location. *)
  | New_session : (client, string) result request
      (** Create a shell session using the current session's cwd and select it; returns its
          location. *)
  | Select_window : switched -> (client, string) result request
      (** Select the given session/window's active pane; returns its location. *)
  | Select_session : Tmux.Session.id -> (client, string) result request
      (** Select the given session's active window and pane; returns their location. *)
  | Jump : client -> (client, string) result request
      (** Switch the client to the given pane, keeping its session; returns where it landed. *)
  | Activate_ask : Ask.id -> (client, string) result request
      (** Jump to the asking pane, reviving its ended session first; returns where it landed. *)
  | Delete_ask : Ask.id -> (unit, string) result request
      (** Delete the ask and notify its live asker best-effort; Ok means it was removed. *)
  | Release_side_focus : (unit, string) result request
      (** Return tmux keyboard focus to the terminal; Ok means the client refresh succeeded. *)

val handle : socket:string option -> dir:string -> client:string -> 'a request -> 'a
