let fields s =
  let spaced = String.map (fun c -> if Char.is_whitespace_ascii c then ' ' else c) s in
  List.filter (Fun.negate String.is_empty) (String.split_on_char ' ' spaced)
