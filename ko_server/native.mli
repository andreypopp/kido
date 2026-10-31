val peer_uid : Unix.file_descr -> int
val peer_pid : Unix.file_descr -> int
val now : unit -> int
val native_signal : int -> int
val write_strings : Unix.file_descr -> string array -> int -> int -> int
