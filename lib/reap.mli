type close = Window of Tmux.window_id | Pane of { window : Tmux.window_id; pane : Tmux.pane_id }

val release : Tmux.t -> close -> (unit, string) result

val decide : State.t -> Tmux.window_id -> close option
(** The close to release for a window, or [None] when it stays open. *)

val collect : Tmux.t -> dir:string -> grace:float -> State.t -> now:float -> unit
