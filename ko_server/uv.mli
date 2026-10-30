val ok : ('a, Luv.Error.t) result -> 'a
val file : Unix.file_descr -> Luv.File.t
val fd : Luv.Pipe.t -> (Unix.file_descr, string) result
val peer_uid : Unix.file_descr -> int
val peer_pid : Unix.file_descr -> int
val now : unit -> int
val sigchld : unit -> int
val native_signal : int -> int
