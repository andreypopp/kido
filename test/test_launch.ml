open Kido

let line_of ~last conf sub =
  List.foldi
    (fun at i line -> if String.mem ~sub line && (last || at < 0) then i else at)
    (-1) (String.lines conf)

(* Positions, not presence: a file that sources the user's config last has every line and
   leaves the server with no sidebar. *)
let%expect_test "server.conf layers kido's defaults, kido.conf, the capture, then kido's options" =
  let conf = Launch.server_conf ~exe:"/p/bin/kido" ~user_conf:"/c/kido/kido.conf" in
  let at = line_of ~last:false conf and last = line_of ~last:true conf in
  let order =
    [
      at "side-status-width";
      at "source-file -q";
      at "@kido-user-command";
      last "set -g side-status-command";
      last "set -g default-command";
    ]
  in
  Printf.printf "found %b, in order %b\n"
    (List.for_all (fun i -> i >= 0) order)
    (List.equal Int.equal order (List.sort Int.compare order));
  let lines = Array.of_list (String.lines conf) in
  print_endline lines.(last "set -g side-status-command");
  print_endline lines.(last "set -g default-command");
  print_endline lines.(at "source-file -q");
  Printf.printf ".tmux.conf named: %b\n" (String.mem ~sub:".tmux.conf" conf);
  [%expect
    {|
    found true, in order true
    set -g side-status-command '/p/bin/kido'
    set -g default-command '/p/bin/kido shell'
    source-file -q '/c/kido/kido.conf'
    .tmux.conf named: false
    |}]

let%expect_test "kido.conf is under XDG_CONFIG_HOME, else ~/.config" =
  print_endline (Launch.user_conf ~xdg_config_home:"/x" ~home:"/h");
  print_endline (Launch.user_conf ~xdg_config_home:"" ~home:"/h");
  (try print_endline (Launch.user_conf ~xdg_config_home:"" ~home:"")
   with Failure msg -> print_endline msg);
  [%expect {|
    /x/kido/kido.conf
    /h/.config/kido/kido.conf
    $HOME is not defined
    |}]

(* The result is also what tmux's default_window_name() (third_party/tmux/names.c) parses, undoing
   at most one layer of quoting: see TestFirstWindowNameIsNotQuoteDebris (e2e). *)
let%expect_test "conf_command double-quotes a path only when sh would split it" =
  print_endline (Launch.conf_command "/opt/homebrew/bin/kido" [ "shell" ]);
  print_endline (Launch.conf_command "/Application Support/kido" [ "shell" ]);
  [%expect {|
    '/opt/homebrew/bin/kido shell'
    '"/Application Support/kido" shell'
    |}]

let%expect_test "a path no nesting of tmux and sh quoting can carry is refused up front" =
  (try print_endline (Launch.server_conf ~exe:"/t/we're here/kido" ~user_conf:"/c/kido.conf")
   with Failure msg -> print_endline msg);
  [%expect
    {| cannot start a kido server: refusing path "/t/we're here/kido": it contains "'", which cannot survive tmux's own command-line parsing |}]

let%expect_test "probe_server reads tmux's failures" =
  List.iter
    (fun (code, stderr) ->
      let bin =
        Sh.write
          (Filename.concat (Sh.temp ()) "tmux")
          (Printf.sprintf "#!/bin/sh\necho '%s' >&2\nexit %d\n" stderr code)
      in
      print_endline
        (match Launch.probe_server bin with Up -> "up" | Down -> "down" | Mismatch -> "mismatch"))
    [
      (0, "");
      (1, "protocol version mismatch (client 8, server 7)");
      (1, "no server running on /tmp/tmux-501/kido");
      (1, "error connecting to /tmp/tmux-501/kido (No such file or directory)");
    ];
  [%expect {|
    up
    mismatch
    down
    down
    |}]

let%expect_test "launching inside tmux refuses, naming the tmux in charge" =
  (try ignore (Launch.run ~tmux:"/tmp/tmux-501/kido,1234,0") with Failure msg -> print_endline msg);
  [%expect {| already inside tmux (/tmp/tmux-501/kido); run kido from a plain terminal |}]
