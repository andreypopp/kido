type id

val parse_id : string -> (id, string) result
val string_of_id : id -> string

type t = {
  id : id;
  session : string;
  session_file : string;
  cwd : string;
  name : string;
  text : string;
  created : Timestamp.t;
}

val read : dir:string -> id -> t option
val list : dir:string -> t list
val revival_error : t -> string option

val caller :
  dir:string ->
  self:Tmux.pane_id option ->
  session:string ->
  ((string * State.session * Tmux_pane.t) option, string) result

val record :
  dir:string ->
  self:string ->
  replaces:id option ->
  session:string ->
  session_file:string ->
  cwd:string ->
  name:string ->
  text:string ->
  now:Timestamp.t ->
  (id, string) result

val target :
  tmux:Tmux.t -> dir:string -> session:Tmux.session_id -> t -> (Tmux.pane_id, string) result

val remove : dir:string -> self:string -> id -> (unit, string) result
val display_name : panes:Tmux_pane.t list -> live:(string * State.session) list -> t -> string
val to_json : panes:Tmux_pane.t list -> live:(string * State.session) list -> t -> Yojson.Safe.t
