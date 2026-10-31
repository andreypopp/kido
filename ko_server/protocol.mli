type cell_px = { width : int; height : int } [@@deriving equal]
(** Pixel size of one cell of the client terminal that sent the size. *)

type size = { cols : int; rows : int; cell_px : cell_px option } [@@deriving equal]
(** Size of a terminal grid. *)

val default_size : size
val valid_size : size -> bool

type cause = Exited of int | Signaled of int | Failed of string
type dead = { at : int; cause : cause }

type row = {
  id : Ids.Pane_id.t;
  pid : int;
  command : string list;
  cwd : string;
  title : string;
  dead : dead option;
}
[@@deriving json]

type version = {
  protocol : string;  (** Protocol version of the server, as "major.minor". *)
  vt : string;
      (** Revision of the pinned third_party/ghostty (libghostty-vt) that the build uses. *)
  build : string;  (** Build id of the ko binary, or "unknown". *)
}
[@@deriving json]
(** The reply of [GET /version]. *)

type error_kind =
  | Invalid
  | Refused
  | Gone
  | Io
  | Missing
  | Protocol_mismatch of version
  | Vt_mismatch of version
[@@deriving to_json]

type error = { kind : error_kind; message : string } [@@deriving to_json]
type key_action = Key_release | Key_press | Key_repeat

type key = {
  action : key_action;
  key : int;
  mods : int;
  unshifted_codepoint : int;
  text : string;
  composing : bool;
}

type mouse_action = Mouse_press | Mouse_release | Mouse_motion

type mouse_button =
  | Button_unknown
  | Button_left
  | Button_right
  | Button_middle
  | Button_four
  | Button_five
  | Button_six
  | Button_seven
  | Button_eight
  | Button_nine
  | Button_ten
  | Button_eleven

type mouse = { action : mouse_action; button : mouse_button; col : int; row : int; mods : int }
type paste = { text : string; check_safe : bool; id : int option }
type command = Argv of string list | Shell of string
type variable = { name : string; value : string }
type history = History_none | History_all
type images = Images_none
type view_options = { history : history; images : images }
type marker = Resize of size | Dead of dead
type created = { pane : Ids.Pane_id.t } [@@deriving json]
type paste_result = { id : int option; pasted : bool; unsafe : bool } [@@deriving json]

module Request : sig
  type client_kind = Terminal | App

  type hello = {
    kind : client_kind;
    name : string;
    pane : Ids.Pane_id.t option;
    focused : bool;
    size : size;
    ignore_size : bool;
  }

  type input = Key of key | Mouse of mouse | Paste of paste | Text of string | Focus of bool
  [@@deriving of_json]

  type client = Hello of hello | Select of Ids.Pane_id.t | Size of size | Focused of bool
  [@@deriving json]

  type create_pane = { cwd : string option; command : command option; env : variable list }
  [@@deriving json]

  type view = Resync of view_options | Input of input [@@deriving json]
  type screen_format = Plain | Ansi
  type screen_history = Visible_only | Full_history | Last_rows of int
end

module Event : sig
  type client =
    | Welcome of { client : Ids.Client_id.t; limits : Config.limits }
    | Topology of row list
    | Title of { pane : Ids.Pane_id.t; title : string }
    | Pwd of { pane : Ids.Pane_id.t; pwd : string }
    | Dead of { pane : Ids.Pane_id.t; dead : dead }
  [@@deriving json]

  type view =
    | Marked of { offset : int; marker : marker }
    | Skipped of { offset : int; from : int; to_ : int }
    | Pasted of paste_result
  [@@deriving json]
end

module Record : sig
  type kind = Output | Snapshot
  type slice = { first : bool; last : bool; screen : bool }

  val header_size : int
  val slice_size : int
  val encode_header : Bytes.t -> int -> kind -> offset:int -> unit
  val offset_of_string : string -> int
  val kind_of_string : string -> kind
  val slice_of_string : string -> int -> slice
end

module Route : sig
  type t =
    | Version
    | List_panes
    | Create_pane
    | Client
    | Delete_pane of Ids.Pane_id.t
    | Input of Ids.Pane_id.t
    | Screen of Ids.Pane_id.t * Request.screen_format * Request.screen_history
    | View of Ids.Pane_id.t * view_options * int option

  val websocket : t -> bool
  val to_request : t -> string * string
  val of_request : meth:string -> string -> t option
end

val version : version
(** The values of this binary. *)

val check_version : protocol:string option -> vt:string option -> (unit, error) result
(** Compare the protocol and terminal revision that a client sent with ours. *)
