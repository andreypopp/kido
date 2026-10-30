type json = Yojson.Safe.t

let json_of_yojson value = value
let yojson_of_json value = value

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

let input_of_yojson json =
  match json with
  | `Assoc [ ("key", _) ] -> Key (key_input_of_yojson json).key
  | `Assoc [ ("mouse", _) ] -> Mouse (mouse_input_of_yojson json).mouse
  | `Assoc [ ("paste", _) ] -> Paste (paste_input_of_yojson json).paste
  | `Assoc [ ("text", _) ] -> Text (text_input_of_yojson json).text
  | `Assoc [ ("focus", _) ] -> Focus (focus_input_of_yojson json).focus
  | _ -> Ppx_yojson_conv_lib.Yojson_conv.of_yojson_error "invalid input event" json

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

let client_input_of_yojson json =
  match json with
  | `Assoc [ ("hello", _) ] -> Hello (hello_message_of_yojson json).hello
  | `Assoc [ ("select", _) ] -> Select (select_message_of_yojson json).select.pane
  | `Assoc [ ("size", _) ] -> Size (size_message_of_yojson json).size
  | `Assoc [ ("focused", _) ] -> Focused (focused_message_of_yojson json).focused
  | _ -> Ppx_yojson_conv_lib.Yojson_conv.of_yojson_error "invalid client message" json

type command = Argv of string list | Shell of string

let command_of_yojson json =
  match json with
  | `String s -> Shell s
  | `List _ -> Argv (list_of_yojson string_of_yojson json)
  | _ -> Ppx_yojson_conv_lib.Yojson_conv.of_yojson_error "invalid command" json

let yojson_of_command = function
  | Shell s -> `String s
  | Argv args -> yojson_of_list yojson_of_string args

type environment = (string * string) list

let environment_of_yojson json =
  match json with
  | `Assoc fields -> List.map (fun (k, v) -> (k, string_of_yojson v)) fields
  | _ -> Ppx_yojson_conv_lib.Yojson_conv.of_yojson_error "env must be an object" json

let yojson_of_environment env = `Assoc (List.map (fun (k, v) -> (k, yojson_of_string v)) env)

type create = {
  cwd : string option; [@default None] [@yojson_drop_if Option.is_none]
  command : command option; [@default None] [@yojson_drop_if Option.is_none]
  env : environment; [@default []]
}
[@@deriving yojson]

type view_options = { history : string; [@default "none"] images : string [@default "none"] }
[@@deriving yojson]

type resync = { resync : view_options } [@@deriving yojson]

let full (options : view_options) =
  if not (String.equal options.images "none") then invalid_arg "P1 supports images=none only";
  match options.history with "none" -> false | "all" -> true | _ -> invalid_arg "invalid history"

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

let client_event_of_yojson json =
  match json with
  | `Assoc [ ("topology", _) ] -> Topology (topology_of_yojson json).topology
  | `Assoc fields when List.mem_assoc ~eq:String.equal "title" fields ->
      Title (title_event_of_yojson json)
  | `Assoc fields when List.mem_assoc ~eq:String.equal "pwd" fields ->
      Pwd (pwd_event_of_yojson json)
  | `Assoc fields when List.mem_assoc ~eq:String.equal "dead" fields ->
      Dead (dead_event_of_yojson json)
  | _ -> Ppx_yojson_conv_lib.Yojson_conv.of_yojson_error "invalid client event" json

type paste_result = {
  id : json option; [@default None] [@yojson_drop_if Option.is_none]
  pasted : bool;
  unsafe : bool;
}
[@@deriving yojson]

type pasted = { paste : paste_result } [@@deriving yojson]
type marker = Resize of Config.size | Dead of dead

let yojson_of_marker = function
  | Resize size -> `Assoc [ ("resize", Config.yojson_of_size size) ]
  | Dead dead -> `Assoc [ ("dead", yojson_of_dead dead) ]

let marker_of_yojson json =
  match json with
  | `Assoc [ ("resize", size) ] -> Resize (Config.size_of_yojson size)
  | `Assoc [ ("dead", dead) ] -> Dead (dead_of_yojson dead)
  | _ -> Ppx_yojson_conv_lib.Yojson_conv.of_yojson_error "invalid marker" json

type marked = { offset : int; marker : marker } [@@deriving yojson]
type skipped_range = { from : int; to_ : int [@key "to"] } [@@deriving yojson]
type skipped = { offset : int; skipped : skipped_range } [@@deriving yojson]
