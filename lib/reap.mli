(** Which subagent panes are finished with, decided from tmux's [@kido_run] option, never from a
    state record; and an ending's notice text and its send to the parent's inbox. [dir] is the state
    directory throughout. *)

val grace : unit -> float
(** Seconds a finished subagent's window is left alone before a sweep may close it, from
    [KIDO_LINGER_SECONDS] (default 30), the same knob pi/kido-agents.ts reads. *)

type close = { window_id : string; pane_id : string option }
(** [pane_id] is [None] when the whole window is to be closed. *)

type ops = { kill_window : string -> unit; kill_pane : string -> unit }

val release : ops -> close -> unit

val decide : Tmux.Pane.t list -> string -> (close, string) result
(** [kido close-run]'s decision for a window: the close to release, or the refusal to print. *)

val capture_pane : string -> string option
(** A pane's screen with 1000 lines of history, or [None] when tmux could not capture it. *)

val capture_own_screen :
  dir:string -> capture:(string -> string option) -> Subrun.id -> string -> string option
(** Saves a run's own pane into its run directory and returns what was saved; [None] for an empty
    pane id or a failed capture. *)

val string_of_result : Subrun.result -> string

type detail = Bash of { unstreamed : int } | Agent of { unreported : bool }
type ending = { meta : Subrun.meta; outcome : Subrun.outcome; detail : detail }

val max_notice_tail_bytes : int

val tail_of_file : string -> int -> string * int
(** The last [max] bytes of a file as valid UTF-8 and how many bytes were dropped from the front, a
    partial leading character counted as dropped. Raises [Sys_error]. *)

val body : dir:string -> ending -> string
val send : dir:string -> ending -> (unit, Msg.error) result

val record_ending : dir:string -> Subrun.meta -> Subrun.outcome -> ending option
(** Writes the outcome and reports the notice the parent is owed when this writer won the write and
    the run has a parent. *)

val sweep :
  dir:string ->
  capture:(string -> string option) ->
  grace:float ->
  Tmux.Pane.t list ->
  (string * State.session) list ->
  now:float ->
  close list * ending list
(** [sessions] must be every live record ([State.load_live]), never a per-pane view. *)

val collect :
  dir:string ->
  capture:(string -> string option) ->
  grace:float ->
  Tmux.Pane.t list ->
  (string * State.session) list ->
  now:float ->
  ops ->
  unit
