type id [@@deriving equal, compare, yojson]

val parse_id : string -> (id, string) result
val new_id : unit -> id
val string_of_id : id -> string
val output_path : dir:string -> id -> string

type optional_id = Tmux.pane_id option [@@deriving yojson]
type parent = Run of id | Pane of Tmux.pane_id [@@deriving equal]

val string_of_parent : parent -> string
val parse_parent : string -> (parent, string) result

type meta = {
  id : id;
  name : string;
  parent : parent option;
  pane : optional_id;
  pid : int;
  cwd : string;
  started_at : Timestamp.t;
}
[@@deriving yojson_of]

val label : meta -> string

type result = Completed | Failed | Died | Stopped
type outcome = { result : result; text : string; at : Timestamp.t option } [@@deriving yojson_of]

val string_of_result : result -> string
val write_command : dir:string -> id -> string list -> unit
val write_meta : dir:string -> meta -> unit
val read_meta : dir:string -> id -> meta option

val record_outcome : dir:string -> id -> outcome -> bool
(** [true] once written; [false] when the write lost: an outcome already exists, or the run's
    directory is gone. *)

val read_screen : dir:string -> id -> string option

type run_outcome_error = No_run of string | Lost of string

val run_outcome :
  dir:string -> result:result -> text:string -> id -> (unit, run_outcome_error) Stdlib.result
(** Records a run's own ending, saving the pane's screen first for a failure. *)

type pane_state = Live | Dead of { status : int option; signal : string option }

val read_outcome : dir:string -> id -> outcome option

val effective_outcome : dir:string -> pane:pane_state option -> meta -> outcome option
(** [pane] is [None] when the run's pane is gone. An outcome file wins; else the pane derives the
    ending. [None] only while the run's pane is alive and the run has no outcome. *)

val list : dir:string -> id list

val save_screen : Tmux.t -> dir:string -> id -> Tmux.pane_id option -> string option
(** Saves a pane's screen with 1000 lines of history, bounded to its tail, into the run's directory
    and returns it; [None] for an empty pane id or a failed capture. *)
