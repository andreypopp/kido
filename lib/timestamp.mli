type t = float [@@deriving yojson]

val now : unit -> t
val to_string : t -> string
val of_string : string -> t option

val duration : float -> string
(** Seconds as Go's [time.Duration] prints them, to the millisecond: ["300ms"], ["1.5s"],
    ["1h2m3s"]. *)
