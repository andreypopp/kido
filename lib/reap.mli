type close = Window of Tmux.window_id | Pane of { window : Tmux.window_id; pane : Tmux.pane_id }

val release : Tmux.t -> close -> (unit, string) result

val decide :
  runs:Run.t Tmux.Pane_map.t -> Tmux_pane.t list -> Tmux.window_id -> (close, string) result
(** [kido close-run]'s decision for a window: the close to release, or the refusal to print. *)

val quote : string -> string
(** A Go [%q]-style double-quoted string: control bytes escaped, non-ASCII kept. *)

type detail = Bash | Streamed of { unstreamed : int } | Agent of { unreported : bool }
type ending = { meta : Run.meta; outcome : Run.outcome; detail : detail }

val send : dir:string -> ending -> (unit, Msg.error) result

val record_ending : dir:string -> Run.meta -> Run.outcome -> ending option
(** Writes the outcome and returns the ending when this writer won the write. *)

val collect :
  Tmux.t ->
  dir:string ->
  grace:float ->
  runs:Run.t Tmux.Pane_map.t ->
  Tmux_pane.t list ->
  now:float ->
  unit
