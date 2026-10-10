module String_map : Map.S with type key = string

type options = {
  interval : float;
  client : string;
  tmux : Tmux.t;
  dir : string;
  threshold : float;
  grace : float;
}

val default_interval : float

type lingering = {
  stamp : (int * float) option;
  name : string;
  parent : string;
  outcome : Subrun.result option;
  kind : Subrun.kind;
  started : Timestamp.t;
}

type ask_target = Live of Tmux.pane_id | Revivable | Unavailable
type ask = { ask : Ask.t; target : ask_target }

type snapshot = {
  client : Tmux_pane.client_state option;
  active : Tmux.pane_id option;
  panes : Tmux_pane.t list;
  states : (string * State.session) Tmux.Pane_map.t;
  wake : float option;
  err : string option;
  lingering : lingering String_map.t;
  asks : ask list;
}

val empty : snapshot

val lingering_subagents :
  dir:string -> Tmux_pane.t list -> lingering String_map.t -> lingering String_map.t

type reading = { wall : Timestamp.t; mono : Mtime.t }
type client = { session : Tmux.session_id; window : Tmux.window_id; pane : Tmux.pane_id }
type role = [ `Plain | `Proc | `Dim ]
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
  pane : Tmux.pane_id;
  window : Tmux.window_id;
  kind : row_kind;
  indicator : indicator option;
  title : span list;
  caption : caption;
  run : run option;
}

type node = Group of { name : string; first : item; rest : item list } | Item of item
and item = { row : row; children : node list }

type section = { id : Tmux.session_id; name : string; current : bool; nodes : node list }
type phase = { running : bool; since : float; drawn : bool; held : Tmux_pane.exit option }

type model = {
  opts : options;
  snap : snapshot;
  sessions : section list;
  pane_data : (Tmux_pane.t * State.pane_kind) Tmux.Pane_map.t;
  client : client option;
  started : float;
  seen : float Tmux.Pane_map.t;
  program_seen : int Tmux.Pane_map.t;
  phases : phase Tmux.Pane_map.t;
  ssh_remote : (string * string) Tmux.Pane_map.t;
  now : unit -> float;
  at : float;
  clock : reading;
}

val make : now:(unit -> float) -> options -> model

val program_indicator :
  model -> Tmux.pane_id -> Tmux.Program_status.t -> Tmux.Program_status.record -> indicator

val attention : model -> Tmux.pane_id -> bool
val poll : ?wait:float -> opts:options -> Tmux.Client.t -> snapshot -> snapshot
val step : model -> snapshot -> model * bool

type direction = Next | Prev
type switched = { session : Tmux.session_id; window : Tmux.window_id }

type _ request =
  | Switch_window : direction -> (switched option, string) result request
      (** Switch the client in sidebar order; returns the target, or None when none is eligible. *)
  | Switch_session : direction -> (switched option, string) result request
      (** Switch the client in session order; returns the target, or None with only one session. *)
  | New_window : Tmux.window_id -> (client, string) result request
      (** Create a shell window in the given session and select it; returns its location. *)
  | New_session : (client, string) result request
      (** Create a shell session using the current session's cwd and select it; returns its
          location. *)
  | Select_window : switched -> (client, string) result request
      (** Select the given session/window's active pane; returns its location. *)
  | Select_session : Tmux.session_id -> (client, string) result request
      (** Select the given session's active window and pane; returns their location. *)
  | Jump : client -> (client, string) result request
      (** Switch the client to the given pane, keeping its session; returns where it landed. *)
  | Activate_ask : Ask.id -> (client, string) result request
      (** Jump to the asking pane, reviving its ended session first; returns where it landed. *)
  | Delete_ask : Ask.id -> (unit, string) result request
      (** Delete the ask and notify its live asker best-effort; Ok means it was removed. *)
  | Release_side_focus : (unit, string) result request
      (** Return tmux keyboard focus to the terminal; Ok means the client refresh succeeded. *)

val handle : tmux:Tmux.t -> dir:string -> client:string -> 'a request -> 'a
