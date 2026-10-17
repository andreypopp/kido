val stall_threshold : unit -> float

val stalled_since :
  root:Tmux.Program_status.record option ->
  threshold:float ->
  wake:Timestamp.t option ->
  now:Timestamp.t ->
  Run.pi ->
  bool

val wake : dir:string -> Timestamp.t option
val record_pause : dir:string -> Timestamp.t -> unit
