open Fixture
open Tmux

let opt f = Option.map_or ~default:"-" f
let time = opt (Printf.sprintf "%.0f")

let show (p : Pane.t) =
  Printf.printf
    "%s %s created=%.0f win=%d %s %s %s %s active=%b pane_active=%b pid=%d cmd=%s cwd=%s alt=%b \
     running=%b start=%s prompt=%s exit=%s line=%S dead=%s run=%s ssh=%s attached=%b title=%S\n"
    p.session_name (Session.to_string p.session_id) p.session_created p.window_index
    (Window.to_string p.window_id) p.window_name p.window_layout (Pane.to_string p.pane_id) p.active
    p.pane_active p.pane_pid p.current_command p.current_path p.alternate_on p.command_running
    (time p.command_start) (time p.last_prompt)
    (opt (fun (e : Pane.exit) -> Printf.sprintf "%d@%.0f" e.code e.at) p.last_exit)
    p.command_line (time p.dead_at) (opt Fun.id p.run)
    (opt (fun (user, host) -> user ^ "@" ^ host) p.ssh)
    p.session_attached p.title

let line = String.concat Pane.sep

let%expect_test "tmux ids validate their sigil and digits" =
  List.iter
    (fun (parse, values) -> List.iter (fun s -> Printf.printf "%S %b\n" s (parse s)) values)
    [
      ((fun s -> Option.is_some (Pane.of_string s)), [ "%0"; "%123"; "@1"; ""; "%"; "%x"; "%1x" ]);
      ((fun s -> Option.is_some (Window.of_string s)), [ "@0"; "@123"; "$1"; ""; "@"; "@x"; "@1x" ]);
      ((fun s -> Option.is_some (Session.of_string s)), [ "$0"; "$123"; "%1"; ""; "$"; "$x"; "$1x" ]);
    ];
  [%expect
    {|
    "%0" true
    "%123" true
    "@1" false
    "" false
    "%" false
    "%x" false
    "%1x" false
    "@0" true
    "@123" true
    "$1" false
    "" false
    "@" false
    "@x" false
    "@1x" false
    "$0" true
    "$123" true
    "%1" false
    "" false
    "$" false
    "$x" false
    "$1x" false
    |}]

let%expect_test "the format: title last, no ticking duration, field count pinned" =
  let tokens = String.split ~by:Pane.sep Pane.format in
  Printf.printf "last=%s duration=%b fields=%d const=%d\n"
    (List.hd (List.rev tokens))
    (String.mem ~sub:"pane_command_duration" Pane.format)
    (List.length tokens) Pane.fields;
  [%expect {| last=#{pane_title} duration=false fields=26 const=26 |}]

let%expect_test "a fixture generated from the format parses into every field" =
  let values =
    List.mapi
      (fun i _ ->
        match i with
        | 1 -> "$1"
        | 4 -> "@4"
        | 7 -> "%7"
        | 8 | 12 | 13 | 19 | 21 | 23 -> "1"
        | 16 -> "16"
        | 24 -> "deploy@realm@example.test"
        | 2 | 3 | 9 | 14 | 15 | 17 | 20 -> string_of_int (1_000_000 + i)
        | _ -> Printf.sprintf "str%d" i)
      (String.split ~by:Pane.sep Pane.format)
  in
  List.iter
    (fun p ->
      show p;
      Option.iter (fun (user, host) -> Printf.printf "user=%S host=%S\n" user host) p.ssh)
    (Pane.parse [ line values ]);
  [%expect
    {|
    str0 $1 created=1000002 win=1000003 @4 str5 str6 %7 active=true pane_active=true pid=1000009 cmd=str10 cwd=str11 alt=true running=true start=1000014 prompt=1000015 exit=16@1000017 line="str18" dead=1000020 run=str22 ssh=deploy@realm@example.test attached=true title="str25"
    user="deploy@realm" host="example.test"
    |}]

let%expect_test
    "parse: a live pane, a junk line, an empty status, a dead run, a title holding the separator" =
  List.iter show
    (Pane.parse
       [
         line
           [
             "work";
             "$1";
             "1700000000";
             "2";
             "@7";
             "win";
             "layout";
             "%3";
             "1";
             "4242";
             "claude";
             "/tmp";
             "0";
             "1";
             "1700000100";
             "1700000050";
             "2";
             "1700000090";
             "make test";
             "0";
             "";
             "1";
             "";
             "1";
             "";
             "✳ Title";
           ];
         "junk";
         line
           [
             "work";
             "$1";
             "1700000000";
             "2";
             "@7";
             "win";
             "layout";
             "%3";
             "0";
             "4242";
             "zsh";
             "/tmp";
             "1";
             "0";
             "";
             "1700000050";
             "";
             "";
             "";
             "0";
             "";
             "0";
             "";
             "1";
             "";
             "zsh";
           ];
         line
           [
             "work";
             "$1";
             "1700000000";
             "2";
             "@7";
             "kid";
             "layout";
             "%3";
             "0";
             "4242";
             "";
             "/tmp";
             "0";
             "0";
             "";
             "";
             "";
             "";
             "";
             "1";
             "1700000200";
             "1";
             "run-abc";
             "0";
             "";
             "kid\x1fmore";
           ];
       ]);
  [%expect
    {|
    work $1 created=1700000000 win=2 @7 win layout %3 active=true pane_active=true pid=4242 cmd=claude cwd=/tmp alt=false running=true start=1700000100 prompt=1700000050 exit=2@1700000090 line="make test" dead=- run=- ssh=- attached=true title="\226\156\179 Title"
    work $1 created=1700000000 win=2 @7 win layout %3 active=false pane_active=true pid=4242 cmd=zsh cwd=/tmp alt=true running=false start=- prompt=1700000050 exit=- line="" dead=- run=- ssh=- attached=false title="zsh"
    work $1 created=1700000000 win=2 @7 kid layout %3 active=false pane_active=false pid=4242 cmd= cwd=/tmp alt=false running=false start=- prompt=- exit=- line="" dead=1700000200 run=run-abc ssh=- attached=true title="kid\031more"
    |}]

let%expect_test "shell: integration, idle, running, the stuck flag healed, a tie read as running" =
  List.iter
    (fun (name, p) ->
      Printf.printf "%s: %s\n" name
        (match Pane.shell p with Unintegrated -> "none" | Idle -> "idle" | Running -> "running"))
    [
      ("no integration", pane "%1");
      ("no integration, stale running flag", pane ~running:true ~start:100. "%1");
      ("idle at the prompt", pane ~prompt:200. ~start:100. "%1");
      ("command running", pane ~running:true ~start:300. ~prompt:200. "%1");
      ( "stuck C without D, healed by the next prompt",
        pane ~running:true ~start:300. ~prompt:400. "%1" );
      ("command started in the prompt's second", pane ~running:true ~start:300. ~prompt:300. "%1");
    ];
  [%expect
    {|
    no integration: none
    no integration, stale running flag: none
    idle at the prompt: idle
    command running: running
    stuck C without D, healed by the next prompt: idle
    command started in the prompt's second: running
    |}]

let show_sessions panes =
  List.iter
    (fun (s : Pane.session) ->
      Printf.printf "%s %s:" s.name (Session.to_string s.id);
      List.iter
        (fun w ->
          Printf.printf " %s[%s]"
            (Window.to_string (List.hd w).Pane.window_id)
            (String.concat " " (List.map (fun (p : Pane.t) -> Pane.to_string p.pane_id) w)))
        s.windows;
      print_newline ())
    (Pane.order_sessions panes)

let%expect_test "order_sessions: oldest session first, windows in list order, panes oldest first" =
  show_sessions
    [
      pane ~session:"b" ~session_id:"$2" ~created:200. ~window:"@3" "%1";
      pane ~session:"b" ~session_id:"$2" ~created:200. ~window:"@4" "%2";
      pane ~session:"a" ~window:"@1" "%3";
      pane ~session:"a" ~window:"@1" "%4";
      pane ~session:"a" ~window:"@2" "%5";
      pane ~session:"c" ~session_id:"$3" ~created:100. ~window:"@5" "%10";
      pane ~session:"c" ~session_id:"$3" ~created:100. ~window:"@5" "%9";
    ];
  [%expect {|
    a $0: @1[%3 %4] @2[%5]
    c $3: @5[%9 %10]
    b $2: @3[%1] @4[%2]
    |}]

let focus_panes =
  [
    pane ~session_id:"$0" ~window:"@1" ~active:true ~attached:true "%1";
    pane ~session_id:"$0" ~window:"@2" ~attached:true "%2";
    pane ~session_id:"$1" ~window:"@3" ~active:true "%3";
    pane ~session_id:"$1" ~window:"@3" ~run:"run-1" "%4";
  ]

let%expect_test "focus, last window, last pane, run pane" =
  List.iter
    (fun w ->
      Printf.printf "%s: focused=%b last_window=%b last_pane=%b run_pane=%s\n" w
        (Pane.window_focused focus_panes (Option.get_exn_or "id" (Window.of_string w)))
        (Pane.last_window focus_panes (Option.get_exn_or "id" (Window.of_string w)))
        (Pane.last_pane focus_panes (Option.get_exn_or "id" (Window.of_string w)))
        (Option.map_or ~default:"-"
           (fun (p : Pane.t) -> Pane.to_string p.pane_id)
           (Pane.run_pane focus_panes (Option.get_exn_or "id" (Window.of_string w)))))
    [ "@1"; "@2"; "@3"; "@999" ];
  [%expect
    {|
    @1: focused=true last_window=false last_pane=true run_pane=-
    @2: focused=false last_window=false last_pane=true run_pane=-
    @3: focused=false last_window=true last_pane=false run_pane=%4
    @999: focused=false last_window=false last_pane=true run_pane=-
    |}]
