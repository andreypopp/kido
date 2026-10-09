type status = Running | Waiting | Compacting | Idle [@@deriving to_yojson]
type agent = Claude | Pi | Other of string [@@deriving to_yojson]
type parent = { session : string; pid : int }

type hook = {
  status : status;
  ended : Timestamp.t option;
  background : bool;
  tool_pending : bool; [@key "toolPending"]
}
[@@deriving to_yojson]

type reporting = Hook of hook | Terminal [@@deriving to_yojson]

type session = {
  agent : agent;
  name : string;
  pane : Tmux.Pane.id option;
      [@to_yojson Tmux.Pane.optional_id_to_yojson] [@of_yojson Tmux.Pane.optional_id_of_yojson]
  pid : int;
  reporting : reporting;
  ts : Timestamp.t;
  inbox : string;
  activity : string;
  parent : parent option;
  depth : int;
  model : string;
}
[@@deriving to_yojson]

val string_of_status : status -> string
val string_of_agent : agent -> string
val agent_of_string : string -> agent
val agent_title : string -> string
val display_name : Tmux.Pane.t list -> session -> string
val addressable_name : session -> bool
val dir : unit -> string
val check_dir : dir:string -> (unit, string) result
val server_socket : create:bool -> dir:string -> (string, string) result
val alive : int -> bool
val get : dir:string -> string -> session option
val get_live : dir:string -> string -> session option
val load_live : dir:string -> (string * session) list
val by_pane : (string * session) list -> (string * session) Tmux.Pane.Map.t
val is_agent_pane : (string * session) Tmux.Pane.Map.t -> pi:Procs.Int_set.t -> Tmux.Pane.t -> bool
val record : dir:string -> string -> session -> (unit, session) result
val remove : dir:string -> string -> pid:int -> (unit, session) result
val held_message : string -> session -> string
val stall_threshold : unit -> float

val stalled_since :
  programs:Tmux.Program_status.t Tmux.Pane.Map.t ->
  threshold:float ->
  wake:Timestamp.t option ->
  now:Timestamp.t ->
  session ->
  bool

val wake : dir:string -> Timestamp.t option
val record_pause : dir:string -> Timestamp.t -> unit
