external peer_uid : Unix.file_descr -> int = "ko_peer_uid"
external peer_pid : Unix.file_descr -> int = "ko_peer_pid"
external now : unit -> int = "ko_now" [@@noalloc]
external native_signal : int -> int = "ko_native_signal" [@@noalloc]

external write_strings : Unix.file_descr -> string array -> int -> int -> int = "ko_write_strings"
[@@noalloc]
