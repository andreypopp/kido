type kind =
  | Init
  | Tail
  | Resize
  | Text
  | Snapshot
  | Exit
  | Ready
  | Head
  | Title
  | Pwd
  | Dead
  | Snapshot_done
  | Error
  | Full
  | Key
  | Paste
  | Paste_done
  | Mouse
  | Focus
  | Screen
  | Signal
[@@deriving equal]

val max_key : int
val number : Buffer.t -> int -> int -> unit
val string : Buffer.t -> string -> unit
val size : Buffer.t -> Config.size -> unit

type slice = { first : bool; last : bool; screen : bool }
type data = Bytes | Resize_marker of Config.size | Dead_marker of Protocol.dead | Slice of slice
type record = private { pos : int; next : int; offset : int; at : int; len : int; data : data }

type event =
  | Ready_pid of int
  | Title_changed of string
  | Pwd_changed of string
  | Record of record
  | Published
  | Failed of Protocol.dead

type t

val create :
  ?callbacks:bool -> Config.t -> id:string -> cwd:string -> argv:string list -> env:string list -> t

val listen : t -> (event -> unit) -> unit
val child_pid : t -> int
val buffer : t -> Luv.Buffer.t
val position : t -> int
val oldest : t -> int option
val alive : t -> bool
val scan : t -> bool
val iter_from : t -> int -> (record -> bool) -> unit
val send : t -> kind -> string -> unit
val paste : t -> string -> ((bool * bool, string) result -> unit) -> unit

val snapshot :
  t -> full:bool -> consume:(record -> unit) -> done_:((unit, string) result -> unit) -> unit

val screen :
  t ->
  ansi:bool ->
  history:int ->
  chunk:(string -> last:bool -> unit) ->
  done_:((unit, string) result -> unit) ->
  unit

val shutdown : t -> unit
val reap : t -> unit
val finished : t -> bool
val kill : t -> unit
