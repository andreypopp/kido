type t =
  | Terminal
  | Some_agent of { name : string }
  | Pi_agent of { id : Run.id; pi : Run.pi }
  | Ssh of { user : string; host : string; pane : ssh_kind }

and ssh_kind = Remote_terminal | Remote_agent of { name : string }

val classify : states:(Run.id * Run.pi) Tmux.Pane_map.t -> State.pane -> t
val title : State.pane -> t -> string option
