type id

val parse_id : string -> (id, string) result
val new_id : unit -> id
val string_of_id : id -> string
val task_path : dir:string -> id -> string
val output_path : dir:string -> id -> string
val report_path : dir:string -> id -> string
val meta_path : dir:string -> id -> string

type kind = Agent | Bash | Stream

val string_of_kind : kind -> string

type meta = {
  id : id;
  name : string;
  kind : kind;
  parent_session : string;
  depth : int;
  pane : Tmux.Pane.id option;
  pid : int;
  cwd : string;
  model : string;
  tools : string list;
  keep_alive : bool;
  started_at : Timestamp.t;
}
[@@deriving yojson]

val label : meta -> string

type result = Completed | Failed | Died | Stopped
type outcome = { result : result; text : string; at : Timestamp.t option } [@@deriving yojson]

val string_of_result : result -> string
val create : dir:string -> id -> string -> unit
val write_command : dir:string -> id -> string list -> unit
val read_command : dir:string -> id -> string list option
val write_meta : dir:string -> meta -> unit
val read_meta : dir:string -> id -> meta option
val write_report : dir:string -> id -> string -> unit
val has_report : dir:string -> id -> bool
val read_task : dir:string -> id -> string option

val record_outcome : dir:string -> id -> outcome -> bool
(** [true] once written; [false] when the write lost: an outcome already exists, or the run's
    directory is gone. *)

val read_screen : dir:string -> id -> string option
val reset_for_resume : dir:string -> id -> delivered:bool -> unit
val read_outcome : dir:string -> id -> outcome option

val effective_outcome : dir:string -> id -> pid:int -> outcome option
(** [None] only while the run is still alive. *)

val list : dir:string -> id list
val truncate_screen : string -> string

val save_screen : ?socket:string -> dir:string -> id -> Tmux.Pane.id option -> string option
(** Saves a pane's screen with 1000 lines of history, bounded to its tail, into the run's directory
    and returns it; [None] for an empty pane id or a failed capture. *)
