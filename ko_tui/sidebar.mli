type row = { pane : Ko_server.Ids.Pane_id.t; text : string; selected : bool } [@@deriving equal]

val rows : selected:Ko_server.Ids.Pane_id.t option -> Ko_server.Protocol.row list -> row list
val pane_x : cols:int -> int
val dead_line : Ko_server.Protocol.dead -> string
val visible : cols:int -> bool
