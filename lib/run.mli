type id [@@deriving equal, compare, yojson]

val parse_id : string -> (id, string) result
val new_id : unit -> id
val string_of_id : id -> string
val task_path : dir:string -> id -> string
val output_path : dir:string -> id -> string
val report_path : dir:string -> id -> string
val meta_path : dir:string -> id -> string

type optional_id = Tmux.pane_id option [@@deriving yojson]
type kind = Pi | Agent | Bash | Stream

val string_of_kind : kind -> string

type meta = {
  id : id;
  name : string;
  kind : kind;
  parent : id option;
  pane : optional_id;
  pid : int;
  cwd : string;
  model : string;
  tools : string list;
  started_at : Timestamp.t;
}
[@@deriving yojson_of]

val label : meta -> string

type pi = {
  pid : int;
  pane : optional_id;
  ts : Timestamp.t;
  inbox : string;
  activity : string;
  model : string;
  name : string;
  session_file : string;
}

val alive : int -> bool
val read_pi : dir:string -> id -> pi option
val live_pi : dir:string -> id -> pi option
val live_parent : dir:string -> id -> (pi, string) result

val write_pi : dir:string -> id -> holder:int -> pi -> (unit, pi) result
(** [Error] is the record of another live process holding the run. *)

val release : dir:string -> id -> holder:int -> (unit, pi) result

type result = Completed | Failed | Died | Stopped
type outcome = { result : result; text : string; at : Timestamp.t option } [@@deriving yojson_of]

val string_of_result : result -> string
val create : dir:string -> id -> string -> unit
val write_command : dir:string -> id -> string list -> unit
val read_command : dir:string -> id -> string list option
val write_meta : dir:string -> meta -> unit

val create_meta : dir:string -> meta -> unit
(** Writes [meta] unless the run already has one. *)

val read_meta : dir:string -> id -> meta option

type t = { meta : meta; pi : pi option }

val load : dir:string -> id -> t option

val name : t -> string
(** The name its pi last reported, else the meta's. *)

val ancestors : dir:string -> meta -> id list
(** The owners above the run, nearest first. *)

val depth : dir:string -> meta -> int
(** The number of parent edges above the run. *)

val write_report : dir:string -> id -> string -> unit
(** Replaces the run's report with the whole delivered report. *)

val has_report : dir:string -> id -> bool
(** The run has delivered a report of its work, not only a status notice. *)

val read_task : dir:string -> id -> string option

val record_outcome : dir:string -> id -> outcome -> bool
(** [true] once written; [false] when the write lost: an outcome already exists, or the run's
    directory is gone. *)

val read_screen : dir:string -> id -> string option

type start = Fresh_start | Continue_session | Restart_task

val prepare_start : dir:string -> id -> start -> unit
val read_outcome : dir:string -> id -> outcome option

val effective_outcome : dir:string -> meta -> outcome option
(** [None] only while the run is still alive. *)

val list : dir:string -> id list

val select : dir:string -> string -> (meta, string) Stdlib.result
(** An exact id first, else a prefix of 8 or more characters, else the live name of a run without an
    outcome. *)

val save_screen : Tmux.t -> dir:string -> id -> Tmux.pane_id option -> string option
(** Saves a pane's screen with 1000 lines of history, bounded to its tail, into the run's directory
    and returns it; [None] for an empty pane id or a failed capture. *)
