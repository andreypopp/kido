val budget : unit -> int option * float option
val afl_source : unit -> string option
val monolith : ?prologue:(unit -> unit) -> fuel:int -> unit -> bool
