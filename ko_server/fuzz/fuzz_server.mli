open Ko_server

type server = { state : State.t; pane : Pane.t; dir : string }

val with_server : command:(string -> string) -> activity:(unit -> bool) -> (server -> 'a) -> 'a
(** Runs [f] with a real ko-pane that runs [command dir] and reads its input from [dir/in]. The
    pane, the scratch directory and the SIGPIPE handler are restored on every exit. *)
