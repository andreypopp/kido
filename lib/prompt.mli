type via = Inbox | Paste
type send = { pane : Tmux.pane_id; target : Tmux.pane_id; text : string }
type error_kind = Refused | Unknown | Invalid
type error = { kind : error_kind; message : string }

type candidate = {
  pane : Tmux.pane_id;
  session : Tmux.session_id;
  window : Tmux.window_id;
  title : string;
}
[@@deriving yojson_of]

val resolve : tmux:Tmux.t -> dir:string -> Tmux.pane_id -> (candidate list, error) result
val send : tmux:Tmux.t -> dir:string -> send -> (via, error) result

type failure = No_prompt | Not_found | Several | Failed of string

val prompt :
  dir:string -> self:Tmux.pane_id option -> window:bool -> string -> (unit, failure) result
