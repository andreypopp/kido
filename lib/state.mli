type status = Running | Waiting | Idle
type agent = Pi | Other of string [@@deriving yojson_of]
type parent = { session : string; pid : int }

type session = {
  agent : agent;
  name : string;
  pane : Tmux_pane.optional_id;
  pid : int;
  ts : Timestamp.t;
  inbox : string;
  activity : string;
  parent : parent option;
  depth : int;
  model : string;
}

val string_of_status : status -> string
val agent_of_string : string -> agent
val display_name : Tmux_pane.t list -> session -> string
val addressable_name : session -> bool
val dir : unit -> string
val check_dir : dir:string -> (unit, string) result
val server_socket : create:bool -> dir:string -> (string, string) result
val alive : int -> bool
val get : dir:string -> string -> session option
val get_live : dir:string -> string -> session option
val load_live : dir:string -> (string * session) list
val by_pane : (string * session) list -> (string * session) Tmux.Pane_map.t

type ssh_kind = Remote_terminal | Remote_agent of { name : string }

type pane_kind =
  | Terminal
  | Some_agent of { name : string }
  | Pi_agent of { id : string; session : session }
  | Ssh of { user : string; host : string; pane : ssh_kind }

val pane_kind : states:(string * session) Tmux.Pane_map.t -> Tmux_pane.t -> pane_kind
val pane_title : Tmux_pane.t -> pane_kind -> string option
val record : dir:string -> string -> session -> (unit, session) result
val remove : dir:string -> string -> pid:int -> (unit, session) result
val stall_threshold : unit -> float

val stalled_since :
  root:Tmux.Program_status.record option ->
  threshold:float ->
  wake:Timestamp.t option ->
  now:Timestamp.t ->
  session ->
  bool

val wake : dir:string -> Timestamp.t option
val record_pause : dir:string -> Timestamp.t -> unit
