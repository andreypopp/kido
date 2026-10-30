type layout = {
  cols : int;
  rows : int;
  pane_x : int;
  pane_rows : int;
  warning : bool;
  sidebar : (string * bool) list;
  choosing : int option;
}
[@@deriving equal]

type t

val create : unit -> t
val invalidate : t -> unit
val draw_ui : layout -> Matrix.Grid.t -> unit
val paint : t -> modes:Modes.t -> layout:layout -> frame:Ko_vt.frame option -> Matrix.Grid.t -> bool
