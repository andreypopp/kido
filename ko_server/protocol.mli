type json = Yojson.Safe.t [@@deriving yojson]

type dead = {
  status : int;
  signal : int;
  at : int;
  error : string option; [@default None] [@yojson_drop_if Option.is_none]
}
[@@deriving yojson]

type row = {
  id : string;
  pid : int;
  command : string list;
  cwd : string;
  title : string;
  dead : dead option;
}
[@@deriving yojson]

type error = {
  kind : string;
  message : string;
  protocol : string option; [@default None] [@yojson_drop_if Option.is_none]
  vt : string option; [@default None] [@yojson_drop_if Option.is_none]
}
[@@deriving yojson]

type key = {
  action : int;
  key : int;
  mods : int;
  unshifted_codepoint : int;
  text : string;
  composing : bool;
}
[@@deriving yojson]

type mouse = { action : int; button : int; col : int; row : int; mods : int } [@@deriving yojson]

type paste = {
  text : string;
  check_safe : bool;
  id : json option; [@default None] [@yojson_drop_if Option.is_none]
}
[@@deriving yojson]

type key_input = { key : key } [@@deriving yojson]
type mouse_input = { mouse : mouse } [@@deriving yojson]
type paste_input = { paste : paste } [@@deriving yojson]
type text_input = { text : string } [@@deriving yojson]
type focus_input = { focus : bool } [@@deriving yojson]
type input = Key of key | Mouse of mouse | Paste of paste | Text of string | Focus of bool

val input_of_yojson : Yojson.Safe.t -> input

type hello = {
  kind : string;
  name : string;
  pane : string option; [@default None] [@yojson_drop_if Option.is_none]
  focused : bool;
  size : Config.size;
  features : string list; [@default []]
  ignore_size : bool; [@default false]
}
[@@deriving yojson]

type hello_message = { hello : hello } [@@deriving yojson]
type selection = { pane : string } [@@deriving yojson]
type select_message = { select : selection } [@@deriving yojson]
type size_message = { size : Config.size } [@@deriving yojson]
type focused_message = { focused : bool } [@@deriving yojson]
type client_input = Hello of hello | Select of string | Size of Config.size | Focused of bool

val client_input_of_yojson : Yojson.Safe.t -> client_input

type command = Argv of string list | Shell of string

val command_of_yojson : Yojson.Safe.t -> command
val yojson_of_command : command -> Yojson.Safe.t

type environment = (string * string) list

val environment_of_yojson : Yojson.Safe.t -> environment
val yojson_of_environment : environment -> Yojson.Safe.t

type create = {
  cwd : string option; [@default None] [@yojson_drop_if Option.is_none]
  command : command option; [@default None] [@yojson_drop_if Option.is_none]
  env : environment; [@default []]
}
[@@deriving yojson]

type view_options = { history : string; [@default "none"] images : string [@default "none"] }
[@@deriving yojson]

type resync = { resync : view_options } [@@deriving yojson]

val full : view_options -> bool

type welcome_id = { client : string } [@@deriving yojson]
type welcome = { welcome : welcome_id } [@@deriving yojson]
type topology_data = { panes : row list } [@@deriving yojson]
type topology = { topology : topology_data } [@@deriving yojson]
type created = { pane : string } [@@deriving yojson]
type title_event = { pane : string; title : string } [@@deriving yojson]
type pwd_event = { pane : string; pwd : string } [@@deriving yojson]
type dead_event = { pane : string; dead : dead } [@@deriving yojson]

type client_event =
  | Topology of topology_data
  | Title of title_event
  | Pwd of pwd_event
  | Dead of dead_event
[@@deriving of_yojson]

type paste_result = {
  id : json option; [@default None] [@yojson_drop_if Option.is_none]
  pasted : bool;
  unsafe : bool;
}
[@@deriving yojson]

type pasted = { paste : paste_result } [@@deriving yojson]
type marker = Resize of Config.size | Dead of dead [@@deriving yojson]
type marked = { offset : int; marker : marker } [@@deriving yojson]
type skipped_range = { from : int; to_ : int [@key "to"] } [@@deriving yojson]
type skipped = { offset : int; skipped : skipped_range } [@@deriving yojson]
