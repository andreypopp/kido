val value : string
val matches : expected:string -> string option -> bool
val hello : expected:string -> string option -> Yojson.Safe.t

type any = Any : 'a Sidebar.request -> any
type input = Request of int * any | Invalid of int * string | Ignored

val decode : string -> input
val error : int -> string -> Yojson.Safe.t
val reply : int -> 'a Sidebar.request -> 'a -> Yojson.Safe.t
val snapshot : Sidebar.model -> Yojson.Safe.t option
