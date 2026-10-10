type id = string

let of_string s =
  if
    String.length s > 1
    && Char.equal s.[0] '%'
    && String.for_all Char.Ascii.is_digit (String.drop 1 s)
  then Some s
  else None

let to_string id = id
let equal = String.equal

let compare a b =
  Int.compare
    (Option.get_or ~default:0 (int_of_string_opt (String.drop 1 a)))
    (Option.get_or ~default:0 (int_of_string_opt (String.drop 1 b)))

module Map = Map.Make (struct
  type t = id

  let compare = String.compare
end)

let id_to_yojson id = `String (to_string id)
let id_of_yojson = function `String s -> Option.to_result "pane" (of_string s) | _ -> Error "pane"

let%test_module "Tests" =
  (module struct
    let%expect_test "tmux ids validate their sigil and digits" =
      List.iter
        (fun (parse, values) -> List.iter (fun s -> Printf.printf "%S %b\n" s (parse s)) values)
        [
          ((fun s -> Option.is_some (of_string s)), [ "%0"; "%123"; "@1"; ""; "%"; "%x"; "%1x" ]);
          ( (fun s -> Option.is_some (Window.of_string s)),
            [ "@0"; "@123"; "$1"; ""; "@"; "@x"; "@1x" ] );
          ( (fun s -> Option.is_some (Session.of_string s)),
            [ "$0"; "$123"; "%1"; ""; "$"; "$x"; "$1x" ] );
        ];
      [%expect
        {|
    "%0" true
    "%123" true
    "@1" false
    "" false
    "%" false
    "%x" false
    "%1x" false
    "@0" true
    "@123" true
    "$1" false
    "" false
    "@" false
    "@x" false
    "@1x" false
    "$0" true
    "$123" true
    "%1" false
    "" false
    "$" false
    "$x" false
    "$1x" false
    |}]
  end)
