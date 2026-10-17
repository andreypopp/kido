val stalled_since :
  root:Tmux.Program_status.record option ->
  threshold:float ->
  wake:Timestamp.t option ->
  now:Timestamp.t ->
  reported_at:Timestamp.t ->
  bool

val wake : dir:string -> Timestamp.t option
val record_pause : dir:string -> Timestamp.t -> unit
