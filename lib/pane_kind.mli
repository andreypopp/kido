type t =
  | Terminal
  | Some_agent of { name : string }
  | Pi_agent of { session : string; name : string; inbox : string; activity : string }
  | Ssh of { user : string; host : string; pane : ssh_kind }

and ssh_kind = Remote_terminal | Remote_agent of { name : string }

val classify : State.pane -> t
val title : State.pane -> t -> string option
