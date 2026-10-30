type row = { pane : string; text : string; selected : bool }

val rows : selected:string option -> Ko_server.Protocol.row list -> row list
val width : int
val visible : cols:int -> bool
