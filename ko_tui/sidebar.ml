type row = { pane : string; text : string; selected : bool }

let width = 24
let visible ~cols = cols >= 100
let pane_x ~cols = min (width + 1) (max 0 (cols - 1))

let dead_line (d : Ko_server.Protocol.dead) =
  let name =
    List.assoc_opt ~eq:Int.equal d.signal
      [
        (1, "SIGHUP");
        (2, "SIGINT");
        (3, "SIGQUIT");
        (6, "SIGABRT");
        (9, "SIGKILL");
        (11, "SIGSEGV");
        (13, "SIGPIPE");
        (14, "SIGALRM");
        (15, "SIGTERM");
      ]
  in
  Printf.sprintf "[%s — Ctrl+D to remove]"
    (if d.signal = 0 then Printf.sprintf "exited %d" d.status
     else
       Printf.sprintf "killed by %s"
         (Option.value name ~default:(Printf.sprintf "signal %d" d.signal)))

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
      List.iter (fun signal -> print_endline (dead_line { dead with signal })) [ 0; 15; 99 ];
      [%expect
        {|
        pane_1 false 1 sh
        pane_2 true 2 build †7
        width 24 visible false true
        [exited 7 — Ctrl+D to remove]
        [killed by SIGTERM — Ctrl+D to remove]
        [killed by signal 99 — Ctrl+D to remove]
        |}]
  end)
