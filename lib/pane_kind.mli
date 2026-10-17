type t =
  | Terminal
  | Some_agent of { name : string }
  | Pi_agent of { id : string; pi : Run.pi }
  | Ssh of { user : string; host : string; pane : ssh_kind }

and ssh_kind = Remote_terminal | Remote_agent of { name : string }

val classify : states:(string * Run.pi) Tmux.Pane_map.t -> Tmux_pane.t -> t
val title : Tmux_pane.t -> t -> string option
