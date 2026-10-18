type close = Window of Tmux.window_id | Pane of { window : Tmux.window_id; pane : Tmux.pane_id }

val release : Tmux.t -> close -> (unit, string) result

val close_of : State.t -> Tmux.window_id -> Tmux.pane_id -> close option
(** The close that collects the pane, or [None] for a session's only pane or window. *)

val collect : Tmux.t -> dir:string -> grace:float -> State.t -> now:float -> unit
