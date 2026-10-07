type id

val of_string : string -> id option
val to_string : id -> string
val equal : id -> id -> bool
val id_to_yojson : id -> Yojson.Safe.t
