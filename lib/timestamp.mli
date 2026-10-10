type t = float [@@deriving yojson]

val now : unit -> t
val to_string : t -> string
val of_string : string -> t option

val duration : float -> string
(** Seconds as Go's [time.Duration] prints them, to the millisecond: ["300ms"], ["1.5s"],
    ["1h2m3s"]. *)

val ms_env : (string -> string option) -> string -> float -> float
(** [ms_env getenv name default]: seconds from a knob holding a positive whole number of
    milliseconds, else [default]. *)
