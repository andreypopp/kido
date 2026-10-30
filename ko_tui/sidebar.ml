type row = { pane : string; text : string; selected : bool }

let width = 24
let visible ~cols = cols >= 100

let rows ~selected panes =
  List.mapi
    (fun i (p : Ko_server.Protocol.row) ->
      let title =
        if String.is_empty p.title then
          match p.command with [] -> p.id | command :: _ -> Filename.basename command
        else p.title
      in
      let status = match p.dead with None -> "" | Some d -> Printf.sprintf " †%d" d.status in
      {
        pane = p.id;
        text = Printf.sprintf "%d %s%s" (i + 1) title status;
        selected = Option.exists (String.equal p.id) selected;
      })
    panes

let%test_module "Tests" =
  (module struct
    let%expect_test "flat list preserves pane titles and dead status" =
      let pane : Ko_server.Protocol.row =
        { id = "pane_1"; pid = 1; command = [ "/bin/sh" ]; cwd = "/"; title = ""; dead = None }
      in
      let dead = { Ko_server.Protocol.status = 7; signal = 0; at = 0; error = None } in
      rows ~selected:(Some "pane_2")
        [ pane; { pane with id = "pane_2"; title = "build"; dead = Some dead } ]
      |> List.iter (fun r -> Printf.printf "%s %b %s\n" r.pane r.selected r.text);
      Printf.printf "width %d visible %b %b\n" width (visible ~cols:99) (visible ~cols:100);
      [%expect
        {|
      pane_1 false 1 sh
      pane_2 true 2 build †7
      width 24 visible false true
    |}]
  end)
