type command = Toggle_sidebar | Pager | New | Remove | Previous | Next | Detach

val command : Matrix_input.Key.event -> command option
val key : Matrix_input.Key.event -> Ko_server.Protocol.key
val mouse : pane_x:int -> Mosaic.Event.mouse -> Ko_server.Protocol.mouse
