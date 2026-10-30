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

val create :
  cols:int ->
  rows:int ->
  scrollback_max_bytes:int ->
  apc_max_bytes:int ->
  kitty_image_storage_limit:int ->
  continuation_max_bytes:int ->
  t

val configure :
  t ->
  scrollback_max_bytes:int ->
  apc_max_bytes:int ->
  kitty_image_storage_limit:int ->
  continuation_max_bytes:int ->
  unit

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
