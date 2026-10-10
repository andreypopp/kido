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
  stamp : (int * float) option;
  name : string;
  parent : string;
  outcome : Subrun.result option;
  kind : Subrun.kind;
  started : Timestamp.t;
}

type ask_target = Live of Tmux.Pane.id | Revivable | Unavailable
type ask = { ask : Ask.t; target : ask_target }

type snapshot = {
  client : Tmux.Exec.client_state option;
  active : Tmux.Pane.id option;
  panes : Tmux_pane.t list;
  states : (string * State.session) Tmux.Pane.Map.t;
  wake : float option;
  err : string option;
  lingering : lingering String_map.t;
  asks : ask list;
}

val empty : snapshot
val shell_run_delay : float
val shell_run_hold : float

val lingering_subagents :
  dir:string -> Tmux_pane.t list -> lingering String_map.t -> lingering String_map.t

type reading = { wall : Timestamp.t; mono : Mtime.t }
type client = { session : Tmux.Session.id; window : Tmux.Window.id; pane : Tmux.Pane.id }
type role = [ `Plain | `Current | `Proc | `Dim | `Err | `Running | `Waiting | `Done | `Stalled ]
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
and item = { row : row; program_rows : program_row list; children : node list }
and program_row = { id : string; indicator : indicator; title : string; caption : string }

type section = { id : Tmux.Session.id; name : string; current : bool; nodes : node list }
type phase = { running : bool; since : float; drawn : bool; held : Tmux_pane.exit option }

type model = {
  opts : options;
  snap : snapshot;
  sessions : section list;
  pane_data : (Tmux_pane.t * State.pane_kind) Tmux.Pane.Map.t;
  client : client option;
  started : float;
  seen : float Tmux.Pane.Map.t;
  program_seen : int Tmux.Pane.Map.t;
  phases : phase Tmux.Pane.Map.t;
  ssh_remote : (string * string) Tmux.Pane.Map.t;
  now : unit -> float;
  at : float;
  clock : reading;
}

val make : now:(unit -> float) -> options -> model
val ssh_remote : model -> Tmux_pane.t -> bool
val classify : model -> model
val track : model -> model
val attention : model -> Tmux.Pane.id -> bool
val shell_indicator : model -> phase -> indicator option
val pane_label : model -> Tmux_pane.t * State.pane_kind -> row
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
