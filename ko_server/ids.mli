module type S = sig
  type t [@@deriving equal, compare, json]

  val make : int -> t
  val of_string : string -> t
  val to_string : t -> string
end

module Pane_id : S
module Client_id : S
