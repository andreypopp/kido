open Kido
open Fixture

let%expect_test "Hook and Terminal names use the pane title" =
  let panes =
    [
      pane ~title:"π - kido" "%1"; pane ~title:"π - review - kido" "%2"; pane ~title:"π - kido" "%3";
    ]
  in
  List.iter
    (fun s -> print_endline (State.display_name panes s))
    [
      session ~agent:Claude ~pane:"%1" Idle;
      session ~agent:Claude ~pane:"%2" Idle;
      session ~pane:"%3" Idle;
    ];
  [%expect {|
    kido
    review - kido
    kido
    |}]

let%expect_test "is_ancestor refuses a self-edge" =
  Printf.printf "%b %b\n"
    (List_runs.is_ancestor [ ("x", "x") ] ~ancestor:"x" "x")
    (List_runs.is_ancestor [ ("c", "b"); ("b", "a") ] ~ancestor:"a" "c");
  [%expect {| false true |}]

let%expect_test "agent_title" =
  List.iter
    (fun t -> Printf.printf "[%s]\n" (State.agent_title t))
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
