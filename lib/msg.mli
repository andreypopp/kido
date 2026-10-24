type error = Unavailable of string | Failed of string

val deliver : ?timeout:float -> path:string -> string -> (unit, error) result
