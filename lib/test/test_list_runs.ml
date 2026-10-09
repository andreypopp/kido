open Kido
open Fixture

let%expect_test "Agent names use the pane title" =
  let panes =
    [
      pane ~title:"π - kido" "%1"; pane ~title:"π - review - kido" "%2"; pane ~title:"π - kido" "%3";
    ]
  in
  List.iter
    (fun s -> print_endline (State.display_name panes s))
    [ session ~agent:Pi ~pane:"%1" (); session ~agent:Pi ~pane:"%2" (); session ~pane:"%3" () ];
  [%expect {|
    π - kido
    π - review - kido
    π - kido
    |}]

let%expect_test "is_ancestor refuses a self-edge" =
  Printf.printf "%b %b\n"
    (List_runs.is_ancestor [ ("x", "x") ] ~ancestor:"x" "x")
    (List_runs.is_ancestor [ ("c", "b"); ("b", "a") ] ~ancestor:"a" "c");
  [%expect {| false true |}]
