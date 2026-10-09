val error : string -> string -> unit

val run : string -> (unit -> int) -> int
(** Runs a command body, printing a raised [Failure], [Sys_error], [Json_error] or [Unix_error] as
    [error name] and returning [1]. *)

val table : string list list -> unit
(** Columns padded two past their widest cell, the last unpadded. *)
