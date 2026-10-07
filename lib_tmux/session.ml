type id = string

let of_string s =
  if
    String.length s > 1
    && Char.equal s.[0] '$'
    && String.for_all Char.Ascii.is_digit (String.drop 1 s)
  then Some s
  else None

let to_string id = id
let equal = String.equal
let id_to_yojson id = `String (to_string id)
