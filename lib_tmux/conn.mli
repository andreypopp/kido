type t
(** A tmux control-mode connection. *)

val create : ?socket:string -> client:string -> unit -> t
val close : t -> unit

val run : t -> command:string -> (string list, string) result
(** Runs one tmux command and returns its reply. *)

val await_notifications : t -> timeout:float -> unit
(** Awaits notifications until the server's panes, windows, sessions or program status change,
    prompting a fresh read, or [timeout] seconds pass. *)

val follow : t -> Session.id -> unit
(** Switches the control client to the session, so that session's notifications arrive. *)

val list_panes : t -> (Pane.t list, string) result
(** Every pane on the server, read over the connection or a one-shot tmux when it is down. *)

val client_state : t -> Exec.client_state option
(** The connection's client's session and focus, read over the connection or a one-shot tmux when it
    is down. *)
