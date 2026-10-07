open Tmux

let touch path =
  Out_channel.with_open_bin path (fun oc -> output_string oc "#!/bin/sh\n");
  Unix.chmod path 0o755

let temp () =
  let dir = Filename.temp_dir "kido-tmux" "" in
  ( dir,
    fun s ->
      String.replace ~sub:dir ~by:"$DIR" (String.replace ~sub:(Unix.realpath dir) ~by:"$DIR" s) )

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
    String.concat Pane.sep [ "/dev/ttys001"; "other"; "$1"; "attached,UTF-8"; "0" ];
    String.concat Pane.sep [ "/dev/ttys012"; "work"; "$0"; "attached,side-status-focus,UTF-8"; "0" ];
    "junk";
  ]

let%expect_test "client state" =
  List.iter
    (fun c ->
      Printf.printf "%s: %s\n" c
        (Option.map_or ~default:"-"
           (fun (s : Exec.client_state) ->
             Printf.sprintf "%s %s focused=%b" s.session (Session.to_string s.session_id) s.focused)
           (Exec.parse_client_state clients c)))
    [ "/dev/ttys012"; "/dev/ttys001"; "/dev/ttys999" ];
  [%expect
    {|
    /dev/ttys012: work $0 focused=true
    /dev/ttys001: other $1 focused=false
    /dev/ttys999: -
    |}]
