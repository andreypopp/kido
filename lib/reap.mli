val grace : unit -> float
(** Seconds a finished subagent's window is left alone before a sweep may close it, from
    [KIDO_LINGER_SECONDS] (default 30), the same knob share/pi/kido-agents.ts reads. *)

type close = Window of string | Pane of { window : string; pane : string }

val release : ?socket:string -> close -> (unit, string) result

val decide : Tmux.Pane.t list -> string -> (close, string) result
(** [kido close-run]'s decision for a window: the close to release, or the refusal to print. *)

val quote : string -> string
(** A Go [%q]-style double-quoted string: control bytes escaped, non-ASCII kept. *)

type detail = Bash of { unstreamed : int } | Agent of { unreported : bool }
type ending = { meta : Subrun.meta; outcome : Subrun.outcome; detail : detail }

val body : dir:string -> ending -> string
val send : dir:string -> ending -> (unit, Msg.error) result

val record_ending : dir:string -> Subrun.meta -> Subrun.outcome -> ending option
(** Writes the outcome and returns the ending when this writer won the write. *)

val collect :
  ?socket:string ->
  dir:string ->
  grace:float ->
  Tmux.Pane.t list ->
  (string * State.session) list ->
  now:float ->
  unit
(** [sessions] must be every live record ([State.load_live]), never a per-pane view. *)
