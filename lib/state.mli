type status = Running | Waiting | Compacting | Idle [@@deriving yojson]
type agent = Claude | Pi | Other of string [@@deriving yojson]
type parent = { session : string; pid : int }

type session = {
  agent : agent;
  pane : string;
  pid : int;
  status : status;
  ts : Timestamp.t;
  title : string;
  inbox : string;
  ended : Timestamp.t option;
  background : bool;
  tool_pending : bool;
  activity : string;
  parent : parent option;
  depth : int;
  model : string;
}
[@@deriving yojson]

module String_map : Map.S with type key = string

val statuses : (string * status) list
val string_of_status : status -> string
val string_of_agent : agent -> string
val agent_of_string : string -> agent
val dir : unit -> string
val alive : int -> bool
val get : dir:string -> string -> session option
val read_all : dir:string -> (string * session) list
val load_live : dir:string -> (string * session) list
val by_pane : (string * session) list -> (string * session) String_map.t
val is_agent_pane : (string * session) String_map.t -> pi:Procs.Int_set.t -> Tmux.Pane.t -> bool
val record : dir:string -> string -> session -> (unit, session) result
val remove : dir:string -> string -> pid:int -> (unit, session) result
val held_message : string -> session -> string
val stall_threshold : unit -> float
val stalled_since : threshold:float -> wake:Timestamp.t option -> now:Timestamp.t -> session -> bool
val wake : dir:string -> Timestamp.t option
val record_pause : dir:string -> Timestamp.t -> unit
val agent_title : string -> string
