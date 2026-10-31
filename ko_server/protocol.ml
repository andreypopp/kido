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

module Record = struct
  type kind = Output | Snapshot
  type slice = { first : bool; last : bool; screen : bool }

  let header_size = 9
  let slice_size = 2

  let encode_header bytes at kind ~offset =
    Bytes.set bytes at (match kind with Output -> '\001' | Snapshot -> '\002');
    Bytes.set_int64_le bytes (at + 1) (Int64.of_int offset)

  let kind_of_string s =
    if String.length s < header_size then invalid_arg "short view record"
    else
      match s.[0] with
      | '\001' -> Output
      | '\002' -> Snapshot
      | _ -> invalid_arg "unknown view record"

  let slice_of_string s at =
    {
      first = Char.code s.[at] land 1 <> 0;
      last = Char.code s.[at] land 2 <> 0;
      screen = Char.code s.[at + 1] = 1;
    }
end

module Route = struct
  type t =
    | Version
    | List_panes
    | Create_pane
    | Client
    | Delete_pane of Ids.Pane_id.t
    | Input of Ids.Pane_id.t
    | Screen of Ids.Pane_id.t * Request.screen_format * Request.screen_history
    | View of Ids.Pane_id.t * view_options * int option

  let websocket = function Client | View _ -> true | _ -> false
  let history_name = function History_none -> "none" | History_all -> "all"

  let to_request route =
    let pane id = "/panes/" ^ Ids.Pane_id.to_string id in
    match route with
    | Version -> ("GET", "/version")
    | List_panes -> ("GET", "/panes")
    | Create_pane -> ("POST", "/panes")
    | Client -> ("GET", "/client")
    | Delete_pane id -> ("DELETE", pane id)
    | Input id -> ("POST", pane id ^ "/input")
    | Screen (id, format, history) ->
        ( "GET",
          Printf.sprintf "%s/screen?format=%s&history=%s" (pane id)
            (match format with Plain -> "plain" | Ansi -> "ansi")
            (match history with
            | Visible_only -> "none"
            | Full_history -> "all"
            | Last_rows n -> string_of_int n) )
    | View (id, { history; images = Images_none }, offset) ->
        ( "GET",
          Printf.sprintf "%s/view?history=%s&images=none%s" (pane id) (history_name history)
            (match offset with Some n -> "&offset=" ^ string_of_int n | None -> "") )

  let query target =
    match String.split_on_char '?' target with
    | [ path ] -> (path, [])
    | [ path; query ] ->
        ( path,
          List.map
            (fun pair ->
              match String.split_on_char '=' pair with
              | [ k; v ] -> (k, v)
              | _ -> invalid_arg "invalid query")
            (String.split_on_char '&' query) )
    | _ -> invalid_arg "invalid target"

  let natural ~max value =
    if String.is_empty value || not (String.for_all (fun c -> Char.(c >= '0' && c <= '9')) value)
    then invalid_arg "invalid number";
    match int_of_string_opt value with
    | Some n when n >= 0 && n <= max -> n
    | _ -> invalid_arg "invalid number"

  let of_request ~meth target =
    let path, args = query target in
    let arg name = List.assoc_opt ~eq:String.equal name args in
    match (meth, String.split_on_char '/' path) with
    | "GET", [ ""; "version" ] -> Some Version
    | "GET", [ ""; "panes" ] -> Some List_panes
    | "POST", [ ""; "panes" ] -> Some Create_pane
    | "GET", [ ""; "client" ] -> Some Client
    | _, "" :: "panes" :: id :: rest -> (
        match Ids.Pane_id.of_string id with
        | exception Invalid_argument _ -> None
        | id -> (
            match (meth, rest) with
            | "DELETE", [] -> Some (Delete_pane id)
            | "POST", [ "input" ] -> Some (Input id)
            | "GET", [ "screen" ] ->
                let format : Request.screen_format =
                  match arg "format" with
                  | None | Some "plain" -> Plain
                  | Some "ansi" -> Ansi
                  | Some _ -> invalid_arg "invalid format"
                in
                let history : Request.screen_history =
                  match arg "history" with
                  | None | Some "none" -> Visible_only
                  | Some "all" -> Full_history
                  | Some n -> Last_rows (natural ~max:0xffffffff n)
                in
                Some (Screen (id, format, history))
            | "GET", [ "view" ] ->
                let history =
                  match arg "history" with
                  | None | Some "none" -> History_none
                  | Some "all" -> History_all
                  | Some _ -> invalid_arg "invalid history"
                in
                let images =
                  match arg "images" with
                  | None | Some "none" -> Images_none
                  | Some _ -> invalid_arg "P1 supports images=none only"
                in
                Some
                  (View (id, { history; images }, Option.map (natural ~max:max_int) (arg "offset")))
            | _ -> None))
    | _ -> None
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
