module type S = sig
  type t [@@deriving equal, compare, json]

  val make : int -> t
  val gen : t QCheck2.Gen.t
  val of_string : string -> t
  val to_string : t -> string
end

module Make (P : sig
  val prefix : string
end) : S = struct
  type t = string

  let equal = String.equal
  let compare = String.compare
  let make n = P.prefix ^ string_of_int n
  let gen = QCheck2.Gen.(map make (oneof_weighted [ (8, 1 -- 2); (1, return 99); (1, nat) ]))

  let of_string s =
    let n = String.length P.prefix in
    if
      String.length s > n
      && String.equal (String.sub s 0 n) P.prefix
      && String.for_all
           (fun c -> Char.(c >= '0' && c <= '9'))
           (String.sub s n (String.length s - n))
    then s
    else invalid_arg (Printf.sprintf "invalid id %S" s)

  let to_string s = s
  let to_json s = `String s

  let of_json json =
    match json with
    | `String s -> (
        try of_string s with Invalid_argument message -> Jsonkit.of_json_error ~json message)
    | _ -> Jsonkit.of_json_error ~json "id must be a string"
end

module Pane_id = Make (struct
  let prefix = "pane_"
end)

module Client_id = Make (struct
  let prefix = "client_"
end)
