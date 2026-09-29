val is_window_id : string -> bool
val window_focused : panes:Tmux.Pane.t list Lazy.t -> string -> int

val switch :
  (client:string -> next:bool -> unit) -> client:string -> side_client:string -> next:bool -> int
