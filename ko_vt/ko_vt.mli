type t
type format = Plain | Vt
type colour = Default | Indexed of int | Rgb of int * int * int [@@deriving equal]
type attributes [@@deriving equal]

type attribute =
  | Bold
  | Italic
  | Underline
  | Inverse
  | Dim
  | Blink
  | Hidden
  | Strikethrough
  | Overline

val has_attribute : attributes -> attribute -> bool

type cursor_shape = Bar | Block | Underline | Hollow_block [@@deriving equal]
type mouse_tracking = Off | Press | Button | Any [@@deriving equal]
type cell = { text : string; width : int; fg : colour; bg : colour; attrs : attributes }

type frame = {
  cols : int;
  rows : int;
  cells : cell array;
  cursor_x : int;
  cursor_y : int;
  cursor_visible : bool;
  cursor_shape : cursor_shape;
  mouse : mouse_tracking;
  keyboard : int;
}

val close : t -> unit
val hold_id : t -> int
val render_delay : t -> float
val render : t -> frame
val scroll : t -> int -> unit
val bottom : t -> bool

type scrollback =
  | Scrollback_disabled
  | Scrollback of { max_bytes : int option; max_lines : int option }

type limits = {
  scrollback : scrollback;
  apc_max_bytes : int;
  kitty_images_max_bytes : int;
  continuation_max_bytes : int;
}

val create : cols:int -> rows:int -> limits:limits -> t
val configure : t -> limits:limits -> unit
val now_ns : unit -> int
val compress_tick : t -> now_ns:int -> int

type memory = { pages : int; compressed_pages : int; resident_bytes : int }

val memory : t -> memory
val write : t -> ?off:int -> ?len:int -> string -> unit
val resize : t -> cols:int -> rows:int -> unit
val dump : t -> format -> string
val dump_history : t -> format -> string
val snapshot : t -> screen:bool -> images:bool -> string
val decode : ?ready:(string -> unit) -> (int -> string) -> full:bool -> t
val decode_string : ?ready:(string -> unit) -> full:bool -> string -> t
val cursor : t -> int * int * bool
val mode : t -> int -> bool
val total_rows : t -> int

val differences : ?history:bool -> ?strip:(string -> string) -> t -> t -> string list
(** The ways in which two terminals differ: plain text, the VT dump, the cursor, the modes that
    clients track, and with [history] the scrollback. [strip] cleans each VT dump first. *)
