type scrollback = Ko_vt.scrollback =
  | Scrollback_disabled
  | Scrollback of { max_bytes : int option; max_lines : int option }
      (** The first limit that it reaches applies. None on a field value means no limit. *)
[@@deriving json]

(** A way to transmit a Kitty image other than inline data. *)
type medium = File | Temp_file | Shared_mem [@@deriving json]

type terminal = Ko_vt.limits = {
  scrollback : scrollback;
  apc_max_bytes : int;
      (** Maximum number of bytes that the APC handler buffers, for all protocols. *)
  kitty_images_max_bytes : int;
  continuation_max_bytes : int;
      (** Maximum number of bytes that the terminal keeps to rebuild an escape sequence or UTF-8
          codepoint that was unfinished at the end of the last write. Snapshots carry these bytes,
          so a decoded mirror can continue the sequence. *)
}
[@@deriving json]

type limits = {
  terminal : terminal;
  media : medium list;
      (** The media from which the terminal loads Kitty images. The empty list enables none of them.
      *)
}
[@@deriving json]

type t = {
  dir : string;  (** The state directory of the server. *)
  socket : string;  (** Path of the unix socket that the server listens on. *)
  pane_exe : string;  (** Absolute path of the ko-pane executable that hosts each pane. *)
  terminfo : string;  (** Directory of the shipped terminfo. Panes get it in TERMINFO_DIRS. *)
  shell : string;  (** Absolute path of the login shell. *)
  limits : limits;  (** Terminal limits for all panes. *)
  env : string list;  (** Environment of the server, as "NAME=value" entries. *)
  cwd : string;  (** Working directory of the server. *)
}
(** Configuration of a running server. [bin/ko.ml] builds it at start. *)

val create : dir:string option -> shell:string option -> scrollback:scrollback -> (t, string) result
(** Resolve the settings of the server. *)

val build : string
(** The build id of the ko binary, or "unknown". *)

val default_scrollback : scrollback
(** Used when no explicit config received. *)

val default_limits : limits
(** The terminal limits of a server, with the default scrollback. *)

val dir : dir:string option -> string
(** The state directory: the given path, else KO_STATE_DIR, else XDG_STATE_HOME/ko, else
    HOME/.local/state/ko. *)

val socket : create:bool -> dir:string -> (string, string) result
(** Check a state directory and return its socket path. [create] makes the directory first. *)
