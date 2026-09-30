open Kido
open Fixture

let%expect_test "display_name falls back to the pane title, stripped of pi's marker" =
  let panes =
    [
      pane ~title:"π - kido" "%1"; pane ~title:"π - review - kido" "%2"; pane ~title:"π - kido" "%3";
    ]
  in
  List.iter
    (fun s -> print_endline (List_agents.display_name panes s))
    [ session ~pane:"%1" Idle; session ~pane:"%2" Idle; session ~pane:"%3" ~title:"π - kido" Idle ];
  [%expect {|
    kido
    review - kido
    π - kido
    |}]

let%expect_test "is_ancestor refuses a self-edge" =
  Printf.printf "%b %b\n"
    (List_agents.is_ancestor [ ("x", "x") ] ~ancestor:"x" "x")
    (List_agents.is_ancestor [ ("c", "b"); ("b", "a") ] ~ancestor:"a" "c");
  [%expect {| false true |}]

let%expect_test "agent_title" =
  List.iter
    (fun t -> Printf.printf "[%s]\n" (List_agents.agent_title t))
    [
      "✳ Tmux config";
      "⠂ Fix it";
      "π - kido - internal";
      "π - cwd";
      "·  2 tasks";
      "Plain";
      "✳️ Ёлка";
      "";
    ];
  [%expect
    {|
    [Tmux config]
    [Fix it]
    [kido - internal]
    [cwd]
    [2 tasks]
    [Plain]
    [Ёлка]
    []
    |}]
