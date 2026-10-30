type t
type format = Plain | Vt

val create :
  cols:int ->
  rows:int ->
  scrollback_max_bytes:int ->
  apc_max_bytes:int ->
  kitty_image_storage_limit:int ->
  continuation_max_bytes:int ->
  t

val write : t -> string -> unit
val resize : t -> cols:int -> rows:int -> unit
val dump : t -> format -> string
val snapshot : t -> screen:bool -> images:bool -> string
val decode : (int -> string) -> full:bool -> t
val cursor : t -> int * int * bool
val mode : t -> int -> bool
val total_rows : t -> int
