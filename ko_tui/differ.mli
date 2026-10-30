type cell = { text : string; width : int; style : Ansi.Style.t } [@@deriving equal]
type t

val create : unit -> t
val invalidate : t -> unit
val draw : t -> cols:int -> cell array -> string
