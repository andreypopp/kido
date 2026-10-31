let ok = function
  | Ok value -> value
  | Error error -> raise (Unix.Unix_error (Unix.EIO, Luv.Error.strerror error, ""))

let file (fd : Unix.file_descr) : Luv.File.t = Obj.magic fd

let fd stream =
  match Luv.Handle.fileno stream with
  | Error error -> Error (Luv.Error.strerror error)
  | Ok storage ->
      Ok (Obj.magic Ctypes.(!@(from_voidp int (to_voidp (addr storage)))) : Unix.file_descr)

external peer_uid : Unix.file_descr -> int = "ko_peer_uid"
external peer_pid : Unix.file_descr -> int = "ko_peer_pid"
external now : unit -> int = "ko_now" [@@noalloc]
external sigchld : unit -> int = "ko_sigchld" [@@noalloc]

type identity = { ppid : int; pgid : int; sid : int; start : int }

external identity : int -> identity option = "ko_process_identity"

let signalable pid = pid > 1 && pid <> Unix.getpid ()

external native_signal : int -> int = "ko_native_signal" [@@noalloc]
