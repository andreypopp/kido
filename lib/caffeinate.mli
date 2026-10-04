type mode = Off | On | Agents
type t = { mode : mode; active : bool }

val grace : unit -> float option
val tick : dir:string -> grace:float -> now:float -> busy:bool -> Tmux.Conn.t -> t option
val toggle : ?socket:string -> unit -> (unit, string) result
