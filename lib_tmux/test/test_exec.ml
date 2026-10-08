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

let%expect_test "window targets: siblings, roots, runs and session occurrences" =
  let p window id = Fixture.pane ~window id in
  let root = p "@1" "%1" and later_pane = p "@1" "%2" in
  let child = Fixture.pane ~window:"@2" ~run:"child" "%3" in
  let sibling = Fixture.pane ~window:"@3" ~run:"sibling" "%4" in
  let grandchild = Fixture.pane ~window:"@4" ~run:"grandchild" "%5" in
  let earlier = p "@5" "%6" in
  let other = Fixture.pane ~session:"b" ~session_id:"$1" ~window:"@6" "%7" in
  let linked = { root with session_name = "b"; session_id = other.session_id } in
  let windows =
    [
      ([ root; later_pane ], None);
      ([ child ], Some later_pane.pane_id);
      ([ grandchild ], Some child.pane_id);
      ([ Fixture.pane ~window:"@9" ~run:"grand-sibling" "%10" ], Some child.pane_id);
      ([ sibling ], Some later_pane.pane_id);
      ([ earlier ], Some root.pane_id);
      ([ p "@7" "%8" ], None);
      ([ Fixture.pane ~window:"@8" ~run:"orphan" "%9" ], None);
      ([ linked ], None);
      ([ other ], None);
    ]
  in
  List.iter
    (fun (session, window, next) ->
      let target =
        Exec.window_target ~next
          ~session:(Option.get_exn_or "session" (Session.of_string session))
          ~window:(Option.get_exn_or "window" (Window.of_string window))
          windows
      in
      Printf.printf "%s:%s %s -> %s\n" session window
        (if next then "next" else "prev")
        (Option.map_or ~default:"null"
           (fun (p : Pane.t) -> Session.to_string p.session_id ^ ":" ^ Window.to_string p.window_id)
           target))
    [
      ("$0", "@1", true);
      ("$0", "@5", true);
      ("$0", "@5", false);
      ("$0", "@2", false);
      ("$0", "@2", true);
      ("$0", "@3", true);
      ("$0", "@4", false);
      ("$0", "@4", true);
      ("$0", "@9", false);
      ("$0", "@9", true);
      ("$0", "@7", true);
      ("$1", "@1", false);
      ("$1", "@6", true);
      ("$0", "@1", false);
    ];
  List.iter
    (fun windows ->
      List.iter
        (fun next ->
          print_endline
            (Option.map_or ~default:"null"
               (fun (p : Pane.t) -> Window.to_string p.window_id)
               (Exec.window_target ~next ~session:root.session_id ~window:root.window_id windows)))
        [ true; false ])
    [
      [];
      [ ([ root ], None) ];
      [ ([ { root with run = Some "only-run" } ], None) ];
      [ ([ root; { later_pane with run = Some "split-run" } ], None) ];
      [ ([ root ], Pane.of_string "%999") ];
    ];
  [%expect
    {|
    $0:@1 next -> $0:@7
    $0:@5 next -> $0:@2
    $0:@5 prev -> $0:@1
    $0:@2 prev -> $0:@5
    $0:@2 next -> $0:@3
    $0:@3 next -> $0:@7
    $0:@4 prev -> $0:@2
    $0:@4 next -> $0:@9
    $0:@9 prev -> $0:@4
    $0:@9 next -> $0:@7
    $0:@7 next -> $1:@1
    $1:@1 prev -> $0:@7
    $1:@6 next -> $0:@1
    $0:@1 prev -> $1:@6
    null
    null
    @1
    @1
    null
    null
    null
    null
    @1
    @1
    |}]
