val value : string
val matches : string option -> bool
val hello : string option -> Yojson.Safe.t
val reply : int -> ((string * string) option, string) result -> Yojson.Safe.t
