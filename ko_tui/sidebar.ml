type row = { pane : Ko_server.Ids.Pane_id.t; text : string; selected : bool }

let width = 24
let visible ~cols = cols >= 100
let pane_x ~cols = min (width + 1) (max 0 (cols - 1))

let dead_line (d : Ko_server.Protocol.dead) =
  let signal_name signal =
    match
      List.assoc_opt ~eq:Int.equal signal
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
    with
    | Some name -> name
    | None -> Printf.sprintf "signal %d" signal
  in
  Printf.sprintf "[%s — Ctrl+D to remove]"
    (match d.cause with
    | Exited status -> Printf.sprintf "exited %d" status
    | Signaled signal -> Printf.sprintf "killed by %s" (signal_name signal)
    | Failed message -> Printf.sprintf "failed: %s" message)

let rows ~selected panes =
  List.mapi
    (fun i (p : Ko_server.Protocol.row) ->
      let title =
        if String.is_empty p.title then
          match p.command with
          | [] -> Ko_server.Ids.Pane_id.to_string p.id
          | command :: _ -> Filename.basename command
        else p.title
      in
      let status =
        match p.dead with
        | Some { cause = Exited status; _ } -> Printf.sprintf " †%d" status
        | Some _ -> " †"
        | None -> ""
      in
      {
        pane = p.id;
        text = Printf.sprintf "%d %s%s" (i + 1) title status;
        selected = Option.exists (Ko_server.Ids.Pane_id.equal p.id) selected;
      })
    panes

let%test_module "Tests" =
  (module struct
    let%expect_test "flat list preserves pane titles and dead status" =
      let pane : Ko_server.Protocol.row =
        {
          id = Ko_server.Ids.Pane_id.make 1;
          pid = 1;
          command = [ "/bin/sh" ];
          cwd = "/";
          title = "";
          dead = None;
        }
      in
      let dead = { Ko_server.Protocol.at = 0; cause = Exited 7 } in
      rows
        ~selected:(Some (Ko_server.Ids.Pane_id.make 2))
        [ pane; { pane with id = Ko_server.Ids.Pane_id.make 2; title = "build"; dead = Some dead } ]
      |> List.iter (fun r ->
          Printf.printf "%s %b %s\n" (Ko_server.Ids.Pane_id.to_string r.pane) r.selected r.text);
      Printf.printf "width %d visible %b %b\n" width (visible ~cols:99) (visible ~cols:100);
      List.iter
        (fun cause -> print_endline (dead_line { dead with cause }))
        [ Exited 0; Signaled 15; Signaled 99; Failed "boom" ];
      [%expect
        {|
        pane_1 false 1 sh
        pane_2 true 2 build †7
        width 24 visible false true
        [exited 0 — Ctrl+D to remove]
        [killed by SIGTERM — Ctrl+D to remove]
        [killed by signal 99 — Ctrl+D to remove]
        [failed: boom — Ctrl+D to remove]
        |}]
  end)
