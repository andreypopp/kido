module String_map : Map.S with type key = string

type options = {
  interval : float;
  client : string;
  tmux : Tmux.t;
  dir : string;
  threshold : float;
  grace : float;
}

val resolve_client :
  Tmux.t -> pane:Tmux.pane_id option -> session:Tmux.session_id option -> string option

val default_interval : float

type lingering = {
  name : string;
  parent : Run.id option;
  outcome : Run.result option;
  kind : Run.kind;
  started : Timestamp.t;
}

type ask_target = Live of Tmux.pane_id | Revivable | Unavailable
type ask = { ask : Ask.t; name : string; target : ask_target }

type snapshot = {
  server : (int * Tmux.server) option;
  client : Tmux.client option;
  state : State.t;
  visible : State.t;
  wake : float option;
  err : string option;
  lingering : lingering String_map.t;
  asks : ask list;
}

val active : snapshot -> Tmux.pane_id option

type reading = { wall : Timestamp.t; mono : Mtime.t }
type client = { session : Tmux.session_id; window : Tmux.window_id; pane : Tmux.pane_id }
type run = { kind : Run.kind; started : Timestamp.t }

type lifecycle =
  | Live of { status : Pane_status.kind; run : run option }
  | Ended of { result : Run.result option; run : Run.kind }

type row = { pane : Tmux.pane_id; window : Tmux.window_id; title : string; lifecycle : lifecycle }

type node = Group of { name : string; first : item; rest : item list } | Item of item
and item = { row : row; children : node list }

type section = { id : Tmux.session_id; name : string; current : bool; nodes : node list }
type pane = { pane : State.pane; track : Pane_status.track; status : Pane_status.kind }

type model = {
  opts : options;
  snap : snapshot;
  sessions : section list;
  pane_data : pane Tmux.Pane_map.t;
  client : client option;
  now : unit -> float;
  at : float;
  clock : reading;
}

val make : now:(unit -> float) -> options -> model
val poll : ?wait:float -> opts:options -> Tmux.Client.t -> snapshot -> snapshot
val step : model -> snapshot -> model * bool

type direction = Next | Prev
type switched = { session : Tmux.session_id; window : Tmux.window_id }
type position = Before | After
type 'a move = { source : 'a; anchor : 'a; position : position }

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
  | Reorder_session : Tmux.session_id move -> (unit, string) result request
      (** Move a session before or after another in session order, ranking every session. *)
  | Reorder_window : Tmux.session_id * Tmux.window_id move -> (unit, string) result request
      (** Move a top-level window before or after another in its session, keeping the session's
          current window. *)

val handle : tmux:Tmux.t -> dir:string -> client:string -> 'a request -> 'a
