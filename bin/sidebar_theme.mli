type role =
  [ `Plain | `Proc | `Dim | `Session | `Current | `Err | `Running | `Waiting | `Done | `Stalled ]

type t

val default : t
val style : t -> role -> Mosaic.Ansi.Style.t
val current_rows : t -> Mosaic.Ansi.Color.t option
val format : string
val load : string -> t * string option
