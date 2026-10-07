open Kido
open Fixture

let%expect_test "Hook names use the pane title and Terminal names use the root record" =
  let panes =
    [
      pane ~title:"π - kido" "%1"; pane ~title:"π - review - kido" "%2"; pane ~title:"π - kido" "%3";
    ]
  in
  let programs =
    Tmux.Program_status.parse_lines
      [
        "%3\031{\"serial\":1,\"records\":[{\"id\":\"\",\"state\":\"idle\",\"title\":\"z4AgLSBraWRv\"}]}";
      ]
  in
  List.iter
    (fun s -> print_endline (List_runs.display_name ~programs panes s))
    [
      session ~agent:Claude ~pane:"%1" Idle;
      session ~agent:Claude ~pane:"%2" Idle;
      session ~pane:"%3" Idle;
    ];
  [%expect {|
    kido
    review - kido
    π - kido
    |}]

let%expect_test "is_ancestor refuses a self-edge" =
  Printf.printf "%b %b\n"
    (List_runs.is_ancestor [ ("x", "x") ] ~ancestor:"x" "x")
    (List_runs.is_ancestor [ ("c", "b"); ("b", "a") ] ~ancestor:"a" "c");
  [%expect {| false true |}]

let%expect_test "agent_title" =
  List.iter
    (fun t -> Printf.printf "[%s]\n" (List_runs.agent_title t))
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
