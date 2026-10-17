type id [@@deriving equal]

val parse_id : string -> (id, string) result
val new_id : unit -> id
val string_of_id : id -> string
val task_path : dir:string -> id -> string
val output_path : dir:string -> id -> string
val report_path : dir:string -> id -> string
val meta_path : dir:string -> id -> string

type kind = Pi | Agent | Bash | Stream

val string_of_kind : kind -> string

type meta = {
  id : id;
  name : string;
  kind : kind;
  parent : id option;
  pane : Tmux_pane.optional_id;
  pid : int;
  cwd : string;
  model : string;
  tools : string list;
  keep_alive : bool;
  started_at : Timestamp.t;
}
[@@deriving yojson_of]

val label : meta -> string

type pi = {
  pid : int;
  pane : Tmux_pane.optional_id;
  ts : Timestamp.t;
  inbox : string;
  activity : string;
  model : string;
  name : string;
  session_file : string;
}

val alive : int -> bool
val read_pi : dir:string -> id -> pi option
val live_pi : dir:string -> string -> pi option
val live_parent : dir:string -> string -> (pi, string) result
val caller : dir:string -> string -> (id * pi) option

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
val find : dir:string -> string -> meta option

type t = { meta : meta; pi : pi option }

val load : dir:string -> string -> t option
val holder : t -> pi option

val name : t -> string
(** The name its pi last reported, else the meta's. *)

val display_name : Tmux_pane.t list -> pi -> string
(** The name its pi last reported, else the title of the pane it holds. *)

val ancestors : dir:string -> meta -> id list
(** The owners above the run, nearest first. *)

val depth : dir:string -> meta -> int
(** The number of parent edges above the run. *)

val write_report : dir:string -> id -> string -> unit
val has_report : dir:string -> id -> bool
val read_task : dir:string -> id -> string option

val record_outcome : dir:string -> id -> outcome -> bool
(** [true] once written; [false] when the write lost: an outcome already exists, or the run's
    directory is gone. *)

val read_screen : dir:string -> id -> string option
val reset_for_resume : dir:string -> id -> delivered:bool -> unit
val read_outcome : dir:string -> id -> outcome option

val effective_outcome : dir:string -> meta -> outcome option
(** [None] only while the run is still alive. *)

val list : dir:string -> string list

val save_screen : Tmux.t -> dir:string -> id -> Tmux.pane_id option -> string option
(** Saves a pane's screen with 1000 lines of history, bounded to its tail, into the run's directory
    and returns it; [None] for an empty pane id or a failed capture. *)

val marked : dir:string -> Tmux_pane.t list -> t Tmux.Pane_map.t
val window_pane : runs:t Tmux.Pane_map.t -> Tmux_pane.t list -> Tmux.window_id -> Tmux_pane.t option
val agents : t Tmux.Pane_map.t -> (string * pi) Tmux.Pane_map.t
