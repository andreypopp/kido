type close = Window of Tmux.window_id | Pane of { window : Tmux.window_id; pane : Tmux.pane_id }

val release : Tmux.t -> close -> (unit, string) result

val decide :
  runs:Run.t Tmux.Pane_map.t -> Tmux_pane.t list -> Tmux.window_id -> (close, string) result
(** [kido close-run]'s decision for a window: the close to release, or the refusal to print. *)

val collect :
  Tmux.t ->
  dir:string ->
  grace:float ->
  runs:Run.t Tmux.Pane_map.t ->
  Tmux_pane.t list ->
  now:float ->
  unit
