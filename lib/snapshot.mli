val pane_command :
  Tmux.Pane.t -> (string * State.session) State.Panes.t -> pi:Procs.Int_set.t -> string

val snapshot : dir:string -> int
