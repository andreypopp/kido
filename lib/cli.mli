val error : string -> string -> unit
val failf : ('a, unit, string, 'b) format4 -> 'a

val unix_message : Unix.error -> string -> string -> string
(** ["fn arg: message"], the text [run] prints for a [Unix_error]. *)

val run : ?failure:int -> string -> (unit -> int) -> int

val ms_env : (string -> string option) -> string -> float -> float
(** [ms_env getenv name default]: seconds from a knob holding a positive whole number of
    milliseconds, else [default]. *)

val table : string list list -> unit
(** Columns padded two past their widest cell, the last unpadded. *)
