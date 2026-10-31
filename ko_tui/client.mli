type t

type message =
  | Tick
  | Key of Matrix_input.Key.event
  | Mouse of Mosaic.Event.mouse
  | Paste of string
  | Size
  | Focus of bool

val create : wire:Wire.t -> socket:string -> matrix:Matrix.app -> modes:Modes.t -> pager:string -> t
val close : t -> unit
val notify : t -> unit
val paint : t -> unit
val update : t -> message -> unit * message Mosaic.Cmd.t
val start : t -> (message -> unit) -> Matrix_input.t list -> unit
val subscriptions : t -> message Mosaic.Sub.t
