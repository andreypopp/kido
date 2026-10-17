val prepare : ssh:string -> tty:bool -> pane:Tmux.pane_id option -> string list -> string list
(** Marks [pane] with the destination and connection arguments, and returns the argv to exec: the
    remote login shell primed when [tty] and the arguments allow it. *)
