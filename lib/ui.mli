module Style = Mosaic.Ansi.Style

type span = Mosaic.span = { text : string; style : Style.t }

type model = {
  side : Sidebar.model;
  conn : Tmux.Conn.t option;
  standalone : bool;
      (** One-shot picker: q, Esc and C-c quit, and picking a pane jumps and quits. *)
  cursor : int;
  top : int;
  width : int;
  height : int;
  status : string;
  g_pend : bool;
}

val make : ?conn:Tmux.Conn.t -> standalone:bool -> Sidebar.model -> model
val style : Sidebar.role -> Style.t
val spans : Sidebar.line -> span list
val row_text : Sidebar.line -> string
val truncate : int -> span list -> span list

type msg =
  | Snapshot of Sidebar.snapshot
  | Key of Mosaic.Event.key
  | Mouse of Mosaic.Event.mouse
  | Resize of int * int

val update : msg -> model -> model * msg Mosaic.Cmd.t
val run : standalone:bool -> Sidebar.options -> unit
