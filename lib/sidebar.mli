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

type lingering = {
  name : string;
  parent : string;
  outcome : Subrun.result option;
  kind : Subrun.kind;
  started : Timestamp.t;
}

type probe = { reported : float; read : float; dismissed : bool }
type ask_target = Live of string | Revivable | Unavailable
type ask = { ask : Ask.t; target : ask_target }

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

type caption = Text of span list | Elapsed of float
type row_kind = Agent | Run | Ssh | Shell

type row = {
  pane : string;
  window : string;
  kind : row_kind;
  indicator : indicator option;
  title : span list;
  caption : caption;
}

type node = Group of { name : string; first : item; rest : item list } | Item of item
and item = { row : row; children : node list }

type section = { id : string; name : string; current : bool; nodes : node list }
type phase = { running : bool; since : float; drawn : bool; held : Tmux.Pane.exit option }

type model = {
  opts : options;
  snap : snapshot;
  sessions : section list;
  client : client option;
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
  (Tmux.Pane.t list * string option) list

val switch_window :
  socket:string option ->
  dir:string ->
  client:string ->
  next:bool ->
  ((string * string) option, string) result

val filter : string -> section list -> section list
val rebuild : model -> model
val poll : ?wait:float -> opts:options -> Tmux.Conn.t -> snapshot -> snapshot
val step : model -> snapshot -> model * bool

type direction = Next | Prev
type switched = { session : string; window : string }

type _ request =
  | Switch_window : direction -> (switched option, string) result request
  | Switch_session : direction -> (switched option, string) result request
  | New_window : string -> (client, string) result request
  | New_session : (client, string) result request
  | Select_window : switched -> (client, string) result request
  | Select_session : string -> (client, string) result request
  | Jump : client -> (client, string) result request
  | Activate_ask : Ask.id -> (client, string) result request
  | Delete_ask : Ask.id -> (unit, string) result request
  | Release_side_focus : (unit, string) result request

val handle : model -> 'a request -> model * 'a
