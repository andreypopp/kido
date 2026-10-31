type cell_px = { width : int; height : int } [@@deriving equal, json]

type size = { cols : int; rows : int; cell_px : cell_px option [@json.option] [@json.drop_default] }
[@@deriving equal, json]

let default_size = { cols = 80; rows = 24; cell_px = Some { width = 8; height = 16 } }

let valid_size s =
  let in_range n = n > 0 && n <= 65535 in
  in_range s.cols && in_range s.rows
  && match s.cell_px with None -> true | Some c -> in_range c.width && in_range c.height

type cause =
  | Exited of int [@json.name "exited"]
  | Signaled of int [@json.name "signaled"]
  | Failed of string [@json.name "failed"]
[@@deriving json] [@@json.compact_variants]

type dead = { at : int; cause : cause } [@@deriving json]

type row = {
  id : Ids.Pane_id.t;
  pid : int;
  command : string list;
  cwd : string;
  title : string;
  dead : dead option;
}
[@@deriving json]

type version = { protocol : string; vt : string; build : string } [@@deriving json]

type error_kind =
  | Invalid [@json.name "invalid"]
  | Refused [@json.name "refused"]
  | Gone [@json.name "gone"]
  | Io [@json.name "io"]
  | Missing [@json.name "not_found"]
  | Protocol_mismatch of version [@json.name "protocol_mismatch"]
  | Vt_mismatch of version [@json.name "vt_mismatch"]
[@@deriving json] [@@json.compact_variants]

type error = { kind : error_kind; message : string } [@@deriving json]

type key_action =
  | Key_release [@json.name "release"]
  | Key_press [@json.name "press"]
  | Key_repeat [@json.name "repeat"]
[@@deriving json] [@@json.compact_variants]

type key = {
  action : key_action;
  key : int;
  mods : int;
  unshifted_codepoint : int;
  text : string;
  composing : bool;
}
[@@deriving json]

type mouse_action =
  | Mouse_press [@json.name "press"]
  | Mouse_release [@json.name "release"]
  | Mouse_motion [@json.name "motion"]
[@@deriving json] [@@json.compact_variants]

type mouse_button =
  | Button_unknown [@json.name "unknown"]
  | Button_left [@json.name "left"]
  | Button_right [@json.name "right"]
  | Button_middle [@json.name "middle"]
  | Button_four [@json.name "four"]
  | Button_five [@json.name "five"]
  | Button_six [@json.name "six"]
  | Button_seven [@json.name "seven"]
  | Button_eight [@json.name "eight"]
  | Button_nine [@json.name "nine"]
  | Button_ten [@json.name "ten"]
  | Button_eleven [@json.name "eleven"]
[@@deriving json] [@@json.compact_variants]

type mouse = { action : mouse_action; button : mouse_button; col : int; row : int; mods : int }
[@@deriving json]

type paste = {
  text : string;
  check_safe : bool;
  id : int option; [@json.option] [@json.drop_default]
}
[@@deriving json]

type command = Argv of string list [@json.name "argv"] | Shell of string [@json.name "shell"]
[@@deriving json] [@@json.compact_variants]

type variable = { name : string; value : string } [@@deriving json]

type history = History_none [@json.name "none"] | History_all [@json.name "all"]
[@@deriving json] [@@json.compact_variants]

type images = Images_none [@json.name "none"] [@@deriving json] [@@json.compact_variants]

type view_options = {
  history : history; [@json.default History_none]
  images : images; [@json.default Images_none]
}
[@@deriving json]

let full options = match options.history with History_all -> true | History_none -> false

type marker = Resize of size [@json.name "resize"] | Dead of dead [@json.name "dead"]
[@@deriving json] [@@json.compact_variants]

type created = { pane : Ids.Pane_id.t } [@@deriving json]

type paste_result = {
  id : int option; [@json.option] [@json.drop_default]
  pasted : bool;
  unsafe : bool;
}
[@@deriving json]

module Request = struct
  type client_kind = Terminal [@json.name "terminal"] | App [@json.name "app"]
  [@@deriving json] [@@json.compact_variants]

  type hello = {
    kind : client_kind;
    name : string;
    pane : Ids.Pane_id.t option; [@json.option] [@json.drop_default]
    focused : bool;
    size : size;
    ignore_size : bool; [@json.default false]
  }
  [@@deriving json]

  type input =
    | Key of key [@json.name "key"]
    | Mouse of mouse [@json.name "mouse"]
    | Paste of paste [@json.name "paste"]
    | Text of string [@json.name "text"]
    | Focus of bool [@json.name "focus"]
  [@@deriving json] [@@json.compact_variants]

  type client =
    | Hello of hello [@json.name "hello"]
    | Select of Ids.Pane_id.t [@json.name "select"]
    | Size of size [@json.name "size"]
    | Focused of bool [@json.name "focused"]
  [@@deriving json] [@@json.compact_variants]

  type create_pane = {
    cwd : string option; [@json.option] [@json.drop_default]
    command : command option; [@json.option] [@json.drop_default]
    env : variable list; [@json.default []]
  }
  [@@deriving json]

  type view = Resync of view_options [@json.name "resync"] | Input of input [@json.name "input"]
  [@@deriving json] [@@json.compact_variants]

  type screen_format = Plain | Ansi
  type screen_history = Visible_only | Full_history | Last_rows of int
end

module Event = struct
  type client =
    | Welcome of { client : Ids.Client_id.t; limits : Config.limits } [@json.name "welcome"]
    | Topology of row list [@json.name "topology"]
    | Title of { pane : Ids.Pane_id.t; title : string } [@json.name "title"]
    | Pwd of { pane : Ids.Pane_id.t; pwd : string } [@json.name "pwd"]
    | Dead of { pane : Ids.Pane_id.t; dead : dead } [@json.name "dead"]
  [@@deriving json] [@@json.compact_variants]

  type view =
    | Marked of { offset : int; marker : marker } [@json.name "marked"]
    | Skipped of { offset : int; from : int; to_ : int [@json.key "to"] } [@json.name "skipped"]
    | Pasted of paste_result [@json.name "pasted"]
  [@@deriving json] [@@json.compact_variants]
end

let protocol_number = "1.0"
let protocol_major = List.hd (String.split_on_char '.' protocol_number)
let version = { protocol = protocol_number; vt = Vt_revision.value; build = Config.build }

let check_version ~protocol ~vt =
  let refuse kind message = Error { kind; message } in
  let compatible =
    match Option.map (String.split_on_char '.') protocol with
    | Some [ major; minor ] when String.equal major protocol_major -> (
        match int_of_string_opt minor with Some n -> n >= 0 | None -> false)
    | _ -> false
  in
  if not compatible then refuse (Protocol_mismatch version) "protocol major mismatch"
  else if not (Option.exists (String.equal version.vt) vt) then
    refuse (Vt_mismatch version) "terminal revision mismatch"
  else Ok ()
