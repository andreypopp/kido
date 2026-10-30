type size = { cols : int; rows : int; cell_w_px : int; cell_h_px : int } [@@deriving equal, yojson]

type limits = {
  scrollback_max_bytes : int;
  scrollback_max_lines : int option;
  apc_max_bytes : int;
  kitty_image_storage_limit : int;
  media : string list;
  continuation_max_bytes : int;
}
[@@deriving yojson]

type server = { started_at : int; pid : int; build : string } [@@deriving yojson]

type version = { protocol : string; vt : string; server : server; terminal : limits }
[@@deriving yojson]

type t = {
  dir : string;
  pane_exe : string;
  terminfo : string;
  shell : string;
  terminal : limits;
  env : string list;
  cwd : string;
}

val protocol : string
val major : string
val vt : string
val build : string
val default_size : size
val default_scrollback_bytes : int
val limits : ?scrollback_max_bytes:int -> ?scrollback_max_lines:int -> unit -> limits
val valid_size : size -> bool
val default_dir : state:string option -> xdg:string option -> home:string -> string
val socket : create:bool -> string -> (string, string) result
val shipped : unit -> (string * string, string) result
