type id [@@deriving yojson_of]

val parse_id : string -> (id, string) result
val string_of_id : id -> string

type t = { id : id; session : string; text : string; created : Timestamp.t }

val read : dir:string -> id -> t option
val list : dir:string -> t list

val revival : Subrun.run option -> (string * string, string) result
(** The directory and pi session file a revived pi of the ask's run starts from. *)

val caller :
  dir:string -> (Subrun.id * Subrun.pi) option -> ((Subrun.id * Subrun.pi) option, string) result

val record :
  dir:string ->
  replaces:id option ->
  session:string ->
  text:string ->
  now:Timestamp.t ->
  (id, string) result

val target :
  tmux:Tmux.t -> dir:string -> session:Tmux.session_id -> t -> (Tmux.pane_id, string) result

val remove : dir:string -> self:string -> id -> (unit, string) result
val name : panes:Tmux_pane.t list -> Subrun.run option -> string
val to_json : panes:Tmux_pane.t list -> t -> Subrun.run option -> Yojson.Safe.t
