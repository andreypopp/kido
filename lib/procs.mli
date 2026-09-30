module Int_map : Map.S with type key = int
module Int_set : Set.S with type elt = int

type ssh_session = { host : string; interactive : bool }
type scan = { ssh : ssh_session Int_map.t; pi : Int_set.t }
type ssh_args = { opts : string list; letters : string; dest : string; command : string list }
type process = { pid : int; ppid : int; comm : string; args : string list }

val parse_ssh : string list -> ssh_args option
val ssh_session : string list -> ssh_session option
val split_fields : string -> string list list
val parse_processes : string list list -> process list
val parse_parent : string list list -> (int * string) option
val sweep : unit -> scan
val maybe_pi : string -> bool
val reporter_pid : unit -> int
