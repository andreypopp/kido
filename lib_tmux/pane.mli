type id

val of_string : string -> id option
val to_string : id -> string
val equal : id -> id -> bool
val id_to_yojson : id -> Yojson.Safe.t
val id_of_yojson : Yojson.Safe.t -> (id, string) result

module Map : Map.S with type key = id

val compare : id -> id -> int
