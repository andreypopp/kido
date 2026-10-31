type watch
type interest = Idle | Read | Write | Read_write
type window = { mutable buffer : Bigstringaf.t; mutable off : int; mutable len : int }

type source =
  | Stream of { window : window; on_data : int -> unit; on_end : unit -> unit }
  | Ready of (unit -> unit)

val interest_of : read:bool -> write:bool -> interest
val watch : Unix.file_descr -> watch
val handle : watch -> source -> on_writable:(unit -> unit) -> unit
val fd : watch -> Unix.file_descr
val interest : watch -> interest -> unit
val unwatch : watch -> unit
val close : watch -> unit

type timer

val timer : (unit -> unit) -> timer
val start_timer : timer -> after:int -> repeat:int option -> unit
val stop_timer : timer -> unit
val is_active : timer -> bool
val on_signal : int -> (unit -> unit) -> unit

type step = Wait | Peek

val step : step -> unit
val run : unit -> unit
val stop : unit -> unit
