open Kido

(* Nothing a name is derived to may be a path, empty, or what tmux's parser cannot carry. *)
let%expect_test "a window name derived from the command" =
  List.iter
    (fun c ->
      let name = Async_bash.derived_name [ c ] in
      Printf.printf "%S -> %s%s\n" c name
        (match Launch.tmux_safe "name" name with Ok () -> "" | Error _ -> " UNSAFE"))
    [ "make -j8"; "/usr/bin/env python"; ""; "'"; "./x$y"; String.make 70 'a' ];
  [%expect
    {|
    "make -j8" -> make
    "/usr/bin/env python" -> env
    "" -> bash
    "'" -> bash
    "./x$y" -> xy
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" -> aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    |}]
