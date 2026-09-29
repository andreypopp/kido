let error name msg = Printf.eprintf "kido %s: %s\n%!" name msg

let run ?(failure = 1) name body =
  let fail msg =
    error name msg;
    failure
  in
  match body () with
  | code -> code
  | exception Failure msg -> fail msg
  | exception Sys_error msg -> fail msg
  | exception Yojson.Json_error msg -> fail msg
  | exception Unix.Unix_error (e, fn, arg) ->
      fail
        (String.concat " " (List.filter (fun s -> not (String.is_empty s)) [ fn; arg ])
        ^ ": " ^ Unix.error_message e)
