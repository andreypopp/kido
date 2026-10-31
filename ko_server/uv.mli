val ok : ('a, Luv.Error.t) result -> 'a
val file : Unix.file_descr -> Luv.File.t
val fd : Luv.Pipe.t -> (Unix.file_descr, string) result

val read_start :
  ?allocate:(int -> Luv.Buffer.t) ->
  Luv.Pipe.t ->
  ((Luv.Buffer.t, Luv.Error.t) result -> unit) ->
  unit

val peer_uid : Unix.file_descr -> int
val peer_pid : Unix.file_descr -> int
val now : unit -> int
val sigchld : unit -> int
val native_signal : int -> int
