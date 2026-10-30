type row = { pane : string; text : string; selected : bool }

val rows : selected:string option -> Ko_server.Protocol.row list -> row list
val pane_x : cols:int -> int
val dead_line : Ko_server.Protocol.dead -> string
val visible : cols:int -> bool
