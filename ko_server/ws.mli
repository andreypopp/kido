type header = { fin : bool; opcode : int; masked : bool; length : int; size : int }

val extension : int -> int
val parse : string -> int -> header option
val encode : ?fin:bool -> ?declared:int -> ?mask:string -> opcode:int -> string -> string
