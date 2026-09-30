open Tmux

let touch path =
  Out_channel.with_open_bin path (fun oc -> output_string oc "#!/bin/sh\n");
  Unix.chmod path 0o755

let temp () =
  let dir = Filename.temp_dir "kido-tmux" "" in
  ( dir,
    fun s ->
      String.replace ~sub:dir ~by:"$DIR" (String.replace ~sub:(Unix.realpath dir) ~by:"$DIR" s) )

let%expect_test "resolve_binary: $KIDO_TMUX, then a kido-tmux beside kido, then tmux on PATH" =
  let dir, show = temp () in
  let exe = Filename.concat dir "kido" in
  touch exe;
  let resolve kido_tmux = print_endline (show (Exec.resolve_binary ~kido_tmux ~path:"" exe)) in
  resolve None;
  touch (Filename.concat dir "kido-tmux");
  resolve (Some "/opt/kido-tmux");
  resolve None;
  resolve (Some "");
  [%expect {|
    tmux
    /opt/kido-tmux
    $DIR/kido-tmux
    $DIR/kido-tmux
    |}]

let%expect_test "a kido-tmux beside the resolved executable is found through a symlinked bin" =
  let dir, show = temp () in
  let bin = Filename.concat dir "bin" and cellar = Filename.concat dir "cellar" in
  Unix.mkdir bin 0o755;
  Unix.mkdir cellar 0o755;
  touch (Filename.concat cellar "kido");
  touch (Filename.concat cellar "kido-tmux");
  Unix.symlink (Filename.concat cellar "kido") (Filename.concat bin "kido");
  let exe = Filename.concat bin "kido" in
  List.iter (fun c -> print_endline (show c)) (Exec.candidates exe);
  print_endline (show (Exec.resolve_binary ~kido_tmux:None ~path:"" exe));
  [%expect {|
    $DIR/bin/kido
    $DIR/cellar/kido
    $DIR/cellar/kido-tmux
    |}]

let%expect_test "invoked_path: a bare name is looked up on PATH and left unresolved" =
  let dir, show = temp () in
  touch (Filename.concat dir "real-kido");
  Unix.symlink (Filename.concat dir "real-kido") (Filename.concat dir "kido-under-test");
  print_endline (show (Exec.invoked_path ~path:("/nonexistent:" ^ dir) "kido-under-test"));
  print_endline (show (Exec.invoked_path ~path:dir (Filename.concat dir "sub/../kido-under-test")));
  Printf.printf "empty falls back to the executable: %b\n"
    (String.equal (Exec.invoked_path ~path:dir "") Sys.executable_name);
  Printf.printf "a missing file falls back too: %b\n"
    (String.equal (Exec.invoked_path ~path:dir "not-there") Sys.executable_name);
  [%expect
    {|
    $DIR/kido-under-test
    $DIR/kido-under-test
    empty falls back to the executable: true
    a missing file falls back too: true
    |}]

let clients =
  [
    String.concat Pane.sep [ "/dev/ttys001"; "other"; "attached,UTF-8"; "0" ];
    String.concat Pane.sep [ "/dev/ttys012"; "work"; "attached,side-status-focus,UTF-8"; "0" ];
    String.concat Pane.sep [ "client-2"; "work"; "attached,control-mode,UTF-8"; "1" ];
    String.concat Pane.sep [ ""; "work"; "attached"; "0" ];
    "junk";
  ]

let%expect_test "client state and the real clients among them" =
  List.iter
    (fun c ->
      Printf.printf "%s: %s\n" c
        (Option.map_or ~default:"-"
           (fun (s : Exec.client_state) -> Printf.sprintf "%s focused=%b" s.session s.focused)
           (Exec.parse_client_state clients c)))
    [ "/dev/ttys012"; "/dev/ttys001"; "/dev/ttys999" ];
  Printf.printf "real: [%s]\n" (String.concat "; " (Exec.real_clients clients));
  [%expect
    {|
    /dev/ttys012: work focused=true
    /dev/ttys001: other focused=false
    /dev/ttys999: -
    real: [/dev/ttys001; /dev/ttys012]
    |}]

let%expect_test "new_window_args: detached, cwd, target, name, one -e per pair, command last" =
  print_endline
    (String.concat " "
       (Exec.new_window_args ~session:"$3" ~name:"worker-1" ~cwd:"/home/dev/project"
          ~env:[ "KIDO_AGENT_DEPTH=1"; "KIDO_AGENT_TASK_FILE=/tmp/t" ]
          [ "pi"; "--name"; "worker-1" ]));
  [%expect
    {| new-window -d -P -F #{window_id}:#{pane_id}:#{pane_pid} -t $3: -n worker-1 -c /home/dev/project -e KIDO_AGENT_DEPTH=1 -e KIDO_AGENT_TASK_FILE=/tmp/t pi --name worker-1 |}]
