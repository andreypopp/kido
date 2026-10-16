val display_name : Tmux_pane.t list -> Subrun.pi -> string
val dir : unit -> string
val check_dir : dir:string -> (unit, string) result
val server_socket : create:bool -> dir:string -> (string, string) result
val runs : dir:string -> Tmux_pane.t list -> Subrun.run Tmux.Pane_map.t

val run_pane :
  runs:Subrun.run Tmux.Pane_map.t -> Tmux_pane.t list -> Tmux.window_id -> Tmux_pane.t option

val agents : Subrun.run Tmux.Pane_map.t -> (string * Subrun.pi) Tmux.Pane_map.t
(** Each pane's agent: the run its mark names, live and holding that pane. *)

type ssh_kind = Remote_terminal | Remote_agent of { name : string }

type pane_kind =
  | Terminal
  | Some_agent of { name : string }
  | Pi_agent of { id : string; pi : Subrun.pi }
  | Ssh of { user : string; host : string; pane : ssh_kind }

val pane_kind : states:(string * Subrun.pi) Tmux.Pane_map.t -> Tmux_pane.t -> pane_kind
val pane_title : Tmux_pane.t -> pane_kind -> string option
val stall_threshold : unit -> float

val stalled_since :
  root:Tmux.Program_status.record option ->
  threshold:float ->
  wake:Timestamp.t option ->
  now:Timestamp.t ->
  Subrun.pi ->
  bool

val wake : dir:string -> Timestamp.t option
val record_pause : dir:string -> Timestamp.t -> unit
