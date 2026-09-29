(** The durable record of one [kido spawn_subagent]: a directory under [<dir>/<id>] holding the task
    text, a meta file describing the spawn, and, once the run ends, an outcome. Never pruned. [dir]
    is the runs directory (the caller's [Filename.concat (State.dir ()) "runs"]). *)

type id

val parse_id : string -> (id, string) result
(** Refuses an id that would name anything other than one directory directly under [dir]: [""], one
    containing a path separator, or one starting with ["."] (so [".."] and [".hidden"] are both
    refused). *)

val new_id : unit -> id
val string_of_id : id -> string
val task_path : dir:string -> id -> string
val command_path : dir:string -> id -> string
val output_path : dir:string -> id -> string
val report_path : dir:string -> id -> string
val delivered_path : dir:string -> id -> string

type kind = Agent | Bash

type meta = {
  id : id;
  name : string;
  kind : kind option;
  parent_session : string;
  depth : int;
  pane : string;
  pid : int;
  cwd : string;
  model : string;
  tools : string list;
  keep_alive : bool;
  started_at : Timestamp.t;
}
[@@deriving yojson]

type result = Completed | Failed | Died | Stopped
type outcome = { result : result; text : string; at : Timestamp.t option } [@@deriving yojson]

val create : dir:string -> id -> string -> unit
(** Writes a new run's directory and its task text, before the tmux window exists: the child may
    read its task the instant tmux starts it. *)

val write_command : dir:string -> id -> string list -> unit

val read_command : dir:string -> id -> string list option
(** [None] when the command file is missing, malformed, or names no command: an empty argv is
    refused rather than read back as an empty exec. *)

val write_meta : dir:string -> meta -> unit
(** Atomic: a same-directory temp file, unique per writer, then rename, so a reader never sees a
    partial write and racing writers never share a temp file. *)

val read_meta : dir:string -> id -> meta option
val write_report : dir:string -> id -> string -> unit
val has_report : dir:string -> id -> bool
val read_task : dir:string -> id -> string option

val record_outcome : dir:string -> id -> outcome -> bool
(** [true] once written; [false] when an outcome for [id] already exists - the first writer to
    observe how a run ended wins. *)

val write_screen : dir:string -> id -> string -> unit
(** Last writer wins: unlike {!record_outcome}, a losing-race capture must not pin a run to a worse
    screen forever. *)

val read_screen : dir:string -> id -> string option

val reset_for_resume : dir:string -> id -> delivered:bool -> unit
(** Clears the state a fresh [--resume] attempt at [id] must not inherit: its recorded outcome and
    captured screen, always, and its delivered marker when [delivered] is true. *)

val read_outcome : dir:string -> id -> outcome option

val effective_outcome : dir:string -> id -> pid:int -> outcome option
(** [None] only while the run is still alive. Otherwise the recorded outcome, or, when there is none
    and [pid] is no longer alive, a [Died] guess that is never persisted. *)

val list : dir:string -> id list

val max_screen_bytes : int
(** Bounds a captured screen: exhaust for a human to read after the fact, not model input. *)

val truncate_screen : string -> string
(** Cuts data to {!max_screen_bytes}, keeping the tail: the interesting part of a wedged screen is
    whatever came last. *)
