type t = float [@@deriving yojson]

val now : unit -> t
val to_string : t -> string
val of_string : string -> t option
