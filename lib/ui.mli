module Style = Mosaic.Ansi.Style

type span = Mosaic.span = { text : string; style : Style.t }

type line =
  | Header of { name : string; current : bool }
  | Row of string * Sidebar.row
  | Message of string
  | Ask of Ask.t * string option

val lines : Sidebar.model -> line array

type mode = Windows | Asks

type model = {
  side : Sidebar.model;
  lines : line array;
  conn : Tmux.Conn.t option;
  standalone : bool;
  cursor : int;
  top : int;
  width : int;
  height : int;
  status : string;
  g_pend : bool;
  mode : mode;
}

val make : ?conn:Tmux.Conn.t -> standalone:bool -> Sidebar.model -> model
val style : Sidebar.role -> Style.t
val elapsed : float -> string
val spans : now:float -> line -> span list
val row_text : now:float -> line -> string
val truncate : int -> span list -> span list

type msg =
  | Snapshot of Sidebar.snapshot
  | Key of Mosaic.Event.key
  | Mouse of Mosaic.Event.mouse
  | Resize of int * int

val next_wait : model -> float
val update : msg -> model -> model * msg Mosaic.Cmd.t
val run : standalone:bool -> Sidebar.options -> unit
