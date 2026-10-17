type id [@@deriving yojson_of]

val parse_id : string -> (id, string) result
val string_of_id : id -> string

type t = { id : id; session : string; text : string; created : Timestamp.t }

val read : dir:string -> id -> t option
val list : dir:string -> t list

val revival : Run.t option -> (string * string, string) result
(** The directory and pi session file a revived pi of the ask's run starts from. *)

val caller : dir:string -> (Run.id * Run.pi) option -> ((Run.id * Run.pi) option, string) result

type entry = { id : id option; text : string }
type entries = entry list [@@deriving of_yojson]
type answer = { id : id; text : string } [@@deriving yojson_of]

val set :
  dir:string -> session:string -> asks:entry list -> now:Timestamp.t -> (answer list, string) result

val target :
  tmux:Tmux.t -> dir:string -> session:Tmux.session_id -> t -> (Tmux.pane_id, string) result

val remove : dir:string -> self:string -> id -> (unit, string) result
val name : panes:Tmux_pane.t list -> Run.t option -> string
val to_json : panes:Tmux_pane.t list -> t -> Run.t option -> Yojson.Safe.t
