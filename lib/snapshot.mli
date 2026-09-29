val pane_command :
  Tmux.Pane.t -> (string * State.session) State.String_map.t -> pi:Procs.Int_set.t -> string

val snapshot : dir:string -> int
