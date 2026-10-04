open Kido

let test_at = 1_700_000_000.
let temp () = Filename.temp_dir "kido-ui" ""

let opts ?(dir = temp ()) () : Sidebar.options =
  {
    interval = Sidebar.default_interval;
    client = "";
    socket = None;
    dir;
    threshold = 180.;
    grace = 30.;
    caffeinate_grace = None;
  }

let pane ?(session = "sess") ?(window = "@1") ?(command = "") ?(title = "") ?(pid = 0) ?run ?dead_at
    ?(alternate = false) ?(running = false) ?start ?prompt ?exit ?(command_line = "")
    ?(active = false) pane_id : Tmux.Pane.t =
  {
    session_name = session;
    session_id = "$0";
    session_created = 0.;
    window_index = 0;
    window_id = window;
    window_name = "";
    window_layout = "";
    pane_id;
    active;
    pane_pid = pid;
    current_command = command;
    current_path = "";
    alternate_on = alternate;
    command_running = running;
    command_start = start;
    last_prompt = prompt;
    last_exit = Option.map (fun (code, at) -> { Tmux.Pane.code; at }) exit;
    command_line;
    dead_at;
    run;
    session_attached = active;
    title;
  }

let agent_pane ?run w p title = pane ~window:w ~title ?run p
let shell_pane w p = pane ~window:w ~command:"zsh" p

let session ?(agent = State.Pi) ?(status = State.Running) ?(title = "") ?(parent = "") ?(depth = 0)
    ?(ts = test_at) ?ended ?(activity = "") pane : State.session =
  {
    agent;
    pane;
    pid = Unix.getpid ();
    status;
    ts;
    title;
    inbox = "";
    ended;
    background = false;
    tool_pending = false;
    activity;
    parent = (if String.is_empty parent then None else Some { State.session = parent; pid = 0 });
    depth;
    model = "";
  }

let agent_state id parent title = (id, session ~title ~parent "")

let states l =
  List.fold_left
    (fun m (pane, (id, s)) -> State.String_map.add pane (id, { s with State.pane }) m)
    State.String_map.empty l

let model ?(dir = temp ()) ?(clock = ref test_at) ?(started = test_at -. 3600.) () =
  let m = Sidebar.make ~now:(fun () -> !clock) (opts ~dir ()) in
  { m with started; at = !clock }

let client session = Some { Tmux.Exec.session; session_id = "$0"; focused = false }
let lines m = Array.to_list (Ui.lines (Sidebar.rebuild m))

let render ?dir ?(current = "sess") ?(at = test_at) panes st =
  let m = model ?dir ~clock:(ref at) () in
  let states = states st in
  let snap =
    {
      Sidebar.empty with
      client = client current;
      panes;
      states;
      lingering = Sidebar.lingering_subagents ~dir:m.opts.dir panes State.String_map.empty;
    }
  in
  List.iter (fun r -> print_endline (Ui.row_text ~now:m.at r)) (lines { m with snap })

let%expect_test "a subagent's window nests under the pane that spawned it" =
  render
    [
      agent_pane "@13" "%22" "orchestrator";
      shell_pane "@13" "%47";
      agent_pane "@20" "%30" "subagent";
    ]
    [
      ("%22", agent_state "root-sess" "" "orchestrator");
      ("%30", agent_state "kid-sess" "root-sess" "subagent");
    ];
  [%expect {|
    sess
    ┌◼orchestrator
    │ └◼subagent
    └ zsh
    |}]

let%expect_test "field() keeps the three cases aligned" =
  render
    [ agent_pane "@1" "%1" "orchestrator"; pane ~title:"idle-agent" "%2"; shell_pane "@1" "%3" ]
    [
      ("%1", agent_state "root-sess" "" "orchestrator");
      ("%2", ("idle-sess", session ~status:Idle ~title:"idle-agent" ""));
    ];
  [%expect {|
    sess
    ┌◼orchestrator
    ├ idle-agent
    └ zsh
    |}]

let%expect_test "sibling subagents form one group" =
  render
    [
      agent_pane "@13" "%22" "orchestrator";
      shell_pane "@13" "%47";
      agent_pane "@20" "%30" "subagent-a";
      agent_pane "@21" "%31" "subagent-b";
      agent_pane "@22" "%32" "subagent-c";
    ]
    [
      ("%22", agent_state "root-sess" "" "orchestrator");
      ("%30", agent_state "kid-a-sess" "root-sess" "subagent-a");
      ("%31", agent_state "kid-b-sess" "root-sess" "subagent-b");
      ("%32", agent_state "kid-c-sess" "root-sess" "subagent-c");
    ];
  [%expect
    {|
    sess
    ┌◼orchestrator
    │ ├◼subagent-a
    │ ├◼subagent-b
    │ └◼subagent-c
    └ zsh
    |}]

let%expect_test "a two-pane sibling keeps its own bracket beside the group glyph" =
  render
    [
      agent_pane "@13" "%22" "orchestrator";
      agent_pane "@20" "%30" "subagent-a";
      shell_pane "@20" "%40";
      agent_pane "@21" "%31" "subagent-b";
    ]
    [
      ("%22", agent_state "root-sess" "" "orchestrator");
      ("%30", agent_state "kid-a-sess" "root-sess" "subagent-a");
      ("%31", agent_state "kid-b-sess" "root-sess" "subagent-b");
    ];
  [%expect
    {|
    sess
    ╶◼orchestrator
      ├┌◼subagent-a
      │└ zsh
      └◼subagent-b
    |}]

let%expect_test "groups at depth two" =
  render
    [
      agent_pane "@1" "%1" "root";
      agent_pane "@2" "%2" "subagent-a";
      agent_pane "@3" "%3" "subagent-b";
      agent_pane "@4" "%4" "grandkid-a1";
      agent_pane "@5" "%5" "grandkid-b1";
      agent_pane "@6" "%6" "grandkid-b2";
    ]
    [
      ("%1", agent_state "root-sess" "" "root");
      ("%2", agent_state "a-sess" "root-sess" "subagent-a");
      ("%3", agent_state "b-sess" "root-sess" "subagent-b");
      ("%4", agent_state "a1-sess" "a-sess" "grandkid-a1");
      ("%5", agent_state "b1-sess" "b-sess" "grandkid-b1");
      ("%6", agent_state "b2-sess" "b-sess" "grandkid-b2");
    ];
  [%expect
    {|
    sess
    ╶◼root
      ├◼subagent-a
      │ └◼grandkid-a1
      └◼subagent-b
        ├◼grandkid-b1
        └◼grandkid-b2
    |}]

let%expect_test "two root agents in one window are the window's own bracket" =
  render
    [ agent_pane "@1" "%1" "first"; agent_pane "@1" "%2" "second" ]
    [ ("%1", agent_state "first-sess" "" "first"); ("%2", agent_state "second-sess" "" "second") ];
  [%expect {|
    sess
    ┌◼first
    └◼second
    |}]

let%expect_test "the parent's column is carried across a nested child, and stops at the last pane" =
  render
    [
      shell_pane "@13" "%10";
      agent_pane "@13" "%22" "orchestrator";
      shell_pane "@13" "%47";
      agent_pane "@20" "%30" "subagent";
      shell_pane "@20" "%31";
    ]
    [
      ("%22", agent_state "root-sess" "" "orchestrator");
      ("%30", agent_state "kid-sess" "root-sess" "subagent");
    ];
  render
    [
      shell_pane "@13" "%10";
      agent_pane "@13" "%22" "orchestrator";
      agent_pane "@20" "%30" "subagent";
    ]
    [
      ("%22", agent_state "root-sess" "" "orchestrator");
      ("%30", agent_state "kid-sess" "root-sess" "subagent");
    ];
  [%expect
    {|
    sess
    ┌ zsh
    ├◼orchestrator
    │ └┌◼subagent
    │  └ zsh
    └ zsh
    sess
    ┌ zsh
    └◼orchestrator
      └◼subagent
    |}]

let%expect_test
    "nesting is the walk's, not the reported depth's; an orphan is a root; a cycle drops nobody" =
  render
    [ agent_pane "@1" "%1" "root"; agent_pane "@2" "%2" "kid"; agent_pane "@3" "%3" "grandkid" ]
    [
      ("%1", agent_state "root-sess" "" "root");
      ("%2", ("kid-sess", session ~title:"kid" ~parent:"root-sess" ~depth:1 ""));
      ("%3", ("gk-sess", session ~title:"grandkid" ~parent:"kid-sess" ~depth:1 ""));
    ];
  render
    [ agent_pane "@1" "%1" "unrelated"; agent_pane "@2" "%2" "orphan" ]
    [
      ("%1", agent_state "other-sess" "" "unrelated");
      ("%2", ("orphan-sess", session ~title:"orphan" ~parent:"elsewhere-sess" ~depth:1 ""));
    ];
  render
    [ agent_pane "@1" "%a" "a"; agent_pane "@2" "%b" "b" ]
    [ ("%a", agent_state "a-sess" "b-sess" "a"); ("%b", agent_state "b-sess" "a-sess" "b") ];
  [%expect
    {|
    sess
    ╶◼root
      └◼kid
        └◼grandkid
    sess
    ╶◼unrelated
    ╶◼orphan
    sess
    ╶◼a
      └◼b
    |}]

let%expect_test "the same state renders the same rows every time" =
  let panes =
    [
      agent_pane "@1" "%1" "root";
      shell_pane "@1" "%2";
      agent_pane "@2" "%3" "kid-a";
      agent_pane "@3" "%4" "kid-b";
      agent_pane "@4" "%5" "grandkid";
    ]
  in
  let st =
    [
      ("%1", agent_state "root-sess" "" "root");
      ("%3", agent_state "a-sess" "root-sess" "kid-a");
      ("%4", agent_state "b-sess" "root-sess" "kid-b");
      ("%5", agent_state "g-sess" "b-sess" "grandkid");
    ]
  in
  let rows () =
    let m = model () in
    let states = states st in
    lines { m with snap = { Sidebar.empty with client = client "sess"; panes; states } }
    |> List.map (Ui.row_text ~now:m.at)
  in
  let want = rows () in
  Printf.printf "stable: %b\n"
    (List.for_all (fun _ -> List.equal String.equal (rows ()) want) (List.range 1 20));
  List.iter print_endline want;
  [%expect
    {|
    stable: true
    sess
    ┌◼root
    │ ├◼kid-a
    │ └◼kid-b
    │   └◼grandkid
    └ zsh
    |}]

let placements windows st lingering =
  List.iter
    (fun (pl : Sidebar.placement) ->
      Printf.printf "%s anchor=%s\n" (List.hd pl.panes).window_id
        (Option.value ~default:"-" pl.anchor))
    (Sidebar.order_windows_by_tree windows (states st) lingering)

let w ?run id = [ pane ~window:("@" ^ id) ?run ("%" ^ id) ]

let%expect_test "order_windows_by_tree: child after parent, anchored to the parent's pane" =
  placements
    [ w "shell"; w "root"; w "child2"; w "child1" ]
    [
      ("%root", ("root-sess", session ""));
      ("%child2", ("", session ~parent:"root-sess" ~depth:1 ""));
      ("%child1", ("", session ~parent:"root-sess" ~depth:1 ""));
    ]
    State.String_map.empty;
  placements
    [ w "shell"; w "orphan" ]
    [ ("%orphan", ("orphan-sess", session ~parent:"elsewhere-sess" ~depth:1 "")) ]
    State.String_map.empty;
  placements
    [ w "root"; w "kid"; w "grandkid" ]
    [
      ("%root", ("root-sess", session ""));
      ("%kid", ("kid-sess", session ~parent:"root-sess" ~depth:1 ""));
      ("%grandkid", ("gk-sess", session ~parent:"kid-sess" ~depth:1 ""));
    ]
    State.String_map.empty;
  placements
    [ w "a"; w "b" ]
    [
      ("%a", ("a-sess", session ~parent:"b-sess" ""));
      ("%b", ("b-sess", session ~parent:"a-sess" ""));
    ]
    State.String_map.empty;
  [%expect
    {|
    @shell anchor=-
    @root anchor=-
    @child2 anchor=%root
    @child1 anchor=%root
    @shell anchor=-
    @orphan anchor=-
    @root anchor=-
    @kid anchor=%root
    @grandkid anchor=%kid
    @a anchor=-
    @b anchor=%a
    |}]

let%expect_test "order_windows_by_tree: the lingering fallback, and a record beating a stale mark" =
  let lingering parent =
    State.String_map.singleton "run-1"
      { Sidebar.name = ""; parent; outcome = None; kind = Agent; started = test_at }
  in
  placements
    [ w "root"; w ~run:"run-1" "kid" ]
    [ ("%root", ("root-sess", session "")) ]
    (lingering "root-sess");
  placements
    [ w "root"; w "other"; w ~run:"run-1" "kid" ]
    [
      ("%root", ("root-sess", session ""));
      ("%other", ("other-sess", session ""));
      ("%kid", ("kid-sess", session ~parent:"root-sess" ""));
    ]
    (lingering "other-sess");
  placements [ w "shell"; w ~run:"run-1" "kid" ] [] (lingering "elsewhere-sess");
  placements [ w ~run:"run-1" "kid" ] [] (lingering "nonexistent-sess");
  placements
    [ [ pane ~window:"@13" "%21"; pane ~window:"@13" "%101" ]; w "kid1"; w "kid2" ]
    [
      ("%21", ("top-sess", session ""));
      ("%101", ("second-sess", session ""));
      ("%kid1", ("kid1-sess", session ~parent:"top-sess" ~depth:1 ""));
      ("%kid2", ("kid2-sess", session ~parent:"second-sess" ~depth:1 ""));
    ]
    State.String_map.empty;
  [%expect
    {|
    @root anchor=-
    @kid anchor=%root
    @root anchor=-
    @kid anchor=%root
    @other anchor=-
    @shell anchor=-
    @kid anchor=-
    @kid anchor=-
    @13 anchor=-
    @kid1 anchor=%21
    @kid2 anchor=%101
    |}]

let new_run ~dir ?(parent = "") ?(kind = Subrun.Agent) ?result name =
  let id = Subrun.new_id () in
  Subrun.create ~dir id "task";
  Subrun.write_meta ~dir
    {
      id;
      name;
      kind;
      parent_session = parent;
      depth = 0;
      pane = "";
      pid = 0;
      cwd = "";
      model = "";
      tools = [];
      keep_alive = false;
      started_at = test_at;
    };
  Option.iter
    (fun result -> ignore (Subrun.record_outcome ~dir id { result; text = ""; at = None }))
    result;
  Subrun.string_of_id id

let%expect_test
    "a lingering subagent shows its own name, dead or alive, and its outcome once recorded" =
  let dir = temp () in
  let id = new_run ~dir "fix the flaky test" in
  render ~dir [ pane ~window:"@20" ~dead_at:1. ~run:id "%30" ] [];
  render ~dir [ pane ~window:"@20" ~run:id "%30" ] [];
  render ~dir [ pane ~window:"@20" ~run:id "%30"; shell_pane "@20" "%31" ] [];
  List.iter
    (fun result ->
      render ~dir [ pane ~window:"@20" ~dead_at:1. ~run:(new_run ~dir ~result "subagent") "%30" ] [])
    [ Subrun.Completed; Failed; Died; Stopped ];
  render ~dir [ pane ~window:"@20" ~dead_at:1. ~run:"no-such-run" "%30" ] [];
  [%expect
    {|
    sess
    ╶×fix the flaky test
    sess
    ╶◼fix the flaky test 0s
    sess
    ┌◼fix the flaky test 0s
    └ zsh
    sess
    ╶✓subagent completed
    sess
    ╶×subagent failed
    sess
    ╶×subagent died
    sess
    ╶×subagent stopped
    sess
    ╶
    |}]

let%expect_test "a running bash run shows its elapsed time, and its outcome once it ended" =
  let dir = temp () in
  let run = new_run ~dir ~kind:Bash "build" in
  List.iter
    (fun d -> render ~dir ~at:(test_at +. d) [ pane ~window:"@20" ~run "%30" ] [])
    [ 0.; 65. ];
  render ~dir ~at:(test_at +. 65.)
    [
      pane ~window:"@20" ~dead_at:1. ~run:(new_run ~dir ~kind:Bash ~result:Completed "build") "%30";
    ]
    [];
  [%expect
    {|
    sess
    ╶◼build 0s
    sess
    ╶◼build 1m05s
    sess
    ╶✓build completed
    |}]

let%expect_test "a live subagent uses its run start unless it has activity text" =
  let dir = temp () in
  let run = new_run ~dir "helper" in
  let panes = [ agent_pane ~run "@20" "%30" "helper" ] in
  List.iter
    (fun activity ->
      render ~dir ~at:(test_at +. 65.) panes
        [ ("%30", (run, session ~activity ~ts:(test_at +. 60.) "")) ])
    [ ""; "checking tests"; "" ];
  [%expect {|
    sess
    ╶◼helper 1m05s
    sess
    ╶◼helper checking tests
    sess
    ╶◼helper 1m05s
    |}]

let%expect_test "elapsed time is compact: seconds, then minutes and seconds, then hours and minutes"
    =
  List.iter
    (fun s -> Printf.printf "%g %s\n" s (Ui.elapsed s))
    [ -3.; 0.; 0.99; 1.; 59.9; 60.; 65.; 3599.; 3600.; 3720.; 90000. ];
  [%expect
    {|
    -3 0s
    0 0s
    0.99 0s
    1 1s
    59.9 59s
    60 1m00s
    65 1m05s
    3599 59m59s
    3600 1h00m
    3720 1h02m
    90000 25h00m
    |}]

(* With the interval alone, a displayed second changes up to a whole tick late. *)
let%expect_test "a live run wakes the tick at its next second boundary" =
  let dir = temp () in
  let clock = ref test_at in
  let wait panes =
    let side, _ =
      Sidebar.step (model ~dir ~clock ())
        {
          Sidebar.empty with
          client = client "sess";
          panes;
          lingering =
            Sidebar.lingering_subagents ~dir panes State.String_map.empty;
        }
    in
    Printf.printf "%.3f\n" (Ui.next_wait (Ui.make ~standalone:false side))
  in
  let bash = [ pane ~window:"@20" ~run:(new_run ~dir ~kind:Bash "build") "%30" ] in
  let agent = [ pane ~window:"@20" ~run:(new_run ~dir "helper") "%30" ] in
  List.iter
    (fun (at, panes) ->
      clock := test_at +. at;
      wait panes)
    [ (2.3, bash); (2.95, bash); (2.95, agent) ];
  [%expect {|
    0.100
    0.050
    0.050
    |}]

let%expect_test
    "a lingering subagent still nests, and a live split of a keepAlive pi is the bug report" =
  let dir = temp () in
  let id = new_run ~dir ~parent:"root-sess" "subagent" in
  render ~dir
    [ agent_pane "@13" "%22" "orchestrator"; pane ~window:"@20" ~dead_at:1. ~run:id "%30" ]
    [ ("%22", agent_state "root-sess" "" "orchestrator") ];
  render
    [
      agent_pane "@13" "%22" "working-on-kido";
      shell_pane "@20" "%5";
      agent_pane ~run:"run-1" "@20" "%4" "helper";
    ]
    [
      ("%22", agent_state "root-sess" "" "working-on-kido");
      ("%4", ("helper-sess", session ~status:Idle ~title:"helper" ~parent:"root-sess" ""));
    ];
  render
    [
      agent_pane "@13" "%21" "top-level";
      agent_pane "@13" "%101" "second";
      agent_pane "@20" "%30" "subagent-b";
    ]
    [
      ("%21", agent_state "top-sess" "" "top-level");
      ("%101", agent_state "second-sess" "" "second");
      ("%30", agent_state "kid-sess" "second-sess" "subagent-b");
    ];
  [%expect
    {|
    sess
    ╶◼orchestrator
      └×subagent
    sess
    ╶◼working-on-kido
      └┌ helper
       └ zsh
    sess
    ┌◼top-level
    └◼second
      └◼subagent-b
    |}]

let%expect_test "lingering entries carry forward; only a missing outcome is re-read" =
  let dir = temp () in
  let id = new_run ~dir "subagent" in
  let panes = [ pane ~window:"@20" ~dead_at:1. ~run:id "%30" ] in
  let first =
    Sidebar.lingering_subagents ~dir panes State.String_map.empty
  in
  let show l =
    let (l : Sidebar.lingering) = State.String_map.find id l in
    Printf.printf "%s %s\n" l.name (Option.map_or ~default:"-" Subrun.string_of_result l.outcome)
  in
  show first;
  Sys.remove (Subrun.meta_path ~dir (Result.get_exn (Subrun.parse_id id)));
  ignore
    (Subrun.record_outcome ~dir
       (Result.get_exn (Subrun.parse_id id))
       { result = Completed; text = ""; at = None });
  show (Sidebar.lingering_subagents ~dir panes first);
  [%expect {|
    subagent -
    subagent completed
    |}]

let%expect_test "agent_title_of" =
  let m = { (model ()) with snap = Sidebar.empty } in
  List.iter
    (fun title ->
      Printf.printf "%s -> %s\n" title
        (Option.value ~default:"(not an agent)"
           (Sidebar.agent_title_of m (pane ~command:"claude" ~title "%1"))))
    [
      "✳ Tmux config";
      "✳ 2 panes";
      "π - kido - kido";
      "π - kido";
      "π - ";
      "plain title";
      "π-no-space";
      "";
      "✳ ";
      "~/src/kido";
    ];
  [%expect
    {|
    ✳ Tmux config -> Tmux config
    ✳ 2 panes -> 2 panes
    π - kido - kido -> kido - kido
    π - kido -> kido
    π -  -> -
    plain title -> plain title
    π-no-space -> π-no-space
     -> -
    ✳  -> -
    ~/src/kido -> src/kido
    |}]

let indicator_name = function
  | None -> "none"
  | Some (Sidebar.Status Running) -> "running"
  | Some Done -> "done"
  | Some Failed -> "failed"
  | Some _ -> "other"

let%expect_test "shell_outcome: the last command's exit since the pane was last looked at" =
  let ended = 1_700_000_100. and visited = 1_700_000_200. in
  let integrated ?(start = 1_700_000_099.) ?exit ?(running = false) () =
    pane ~prompt:ended ~start ~running ?exit "%1"
  in
  let m seen =
    let m = model ~started:test_at () in
    { m with seen }
  in
  let show name m p =
    Printf.printf "%s: %s\n" name
      (Option.map_or ~default:"none"
         (fun (e : Tmux.Pane.exit) -> Printf.sprintf "exit %d at %.0f" e.code e.at)
         (Sidebar.shell_outcome m p))
  in
  show "no integration" (m State.String_map.empty) (pane ~exit:(1, ended) "%1");
  show "running" (m State.String_map.empty)
    (integrated ~running:true ~start:(ended +. 1.) ~exit:(1, ended) ());
  show "clean exit, not yet visited" (m State.String_map.empty) (integrated ~exit:(0, ended) ());
  show "nonzero exit, not yet visited" (m State.String_map.empty) (integrated ~exit:(1, ended) ());
  show "nonzero exit, pane visited since"
    (m (State.String_map.singleton "%1" visited))
    (integrated ~exit:(1, ended) ());
  show "no status on record" (m State.String_map.empty) (integrated ());
  show "no command has run" (m State.String_map.empty) (pane ~prompt:ended ~exit:(0, ended) "%1");
  show "no end time" (m State.String_map.empty) (integrated ~exit:(1, 0.) ());
  [%expect
    {|
    no integration: none
    running: none
    clean exit, not yet visited: exit 0 at 1700000100
    nonzero exit, not yet visited: exit 1 at 1700000100
    nonzero exit, pane visited since: none
    no status on record: none
    no command has run: none
    no end time: none
    |}]

(* Each step says what tmux reports and how much time passed, in milliseconds: tmux's own
   timestamps are whole seconds, and what is tested is kido's observation of the pane. *)
let%expect_test "shell_indicator debounce on a controlled clock" =
  let cases =
    [
      ( "short command draws nothing",
        true,
        [ (0, false, -1); (50, true, -1); (50, true, -1); (50, false, 0) ] );
      ( "long command draws running, then holds",
        true,
        [
          (0, false, -1);
          (100, true, -1);
          (100, true, -1);
          (100, true, -1);
          (700, true, -1);
          (100, false, 0);
          (400, false, 0);
          (100, false, 0);
        ] );
      ( "clean exit elsewhere replaces the green at once",
        false,
        [ (0, false, -1); (100, true, -1); (300, true, -1); (100, false, 0); (500, false, 0) ] );
      ( "failed exit elsewhere replaces the green at once",
        false,
        [ (0, false, -1); (100, true, -1); (300, true, -1); (100, false, 1); (500, false, 1) ] );
      ( "a second command inside the hold keeps the green",
        true,
        [
          (0, false, -1);
          (100, true, -1);
          (300, true, -1);
          (100, false, 0);
          (100, true, 0);
          (50, false, 0);
          (500, false, 0);
        ] );
      ( "a command after the hold starts blank again",
        true,
        [
          (0, false, -1);
          (100, true, -1);
          (300, true, -1);
          (100, false, 0);
          (600, false, 0);
          (100, true, 0);
          (200, true, 0);
        ] );
      ( "a new command keeps the outcome until it is drawn",
        false,
        [
          (0, false, -1);
          (100, true, -1);
          (300, true, -1);
          (100, false, 0);
          (600, false, 0);
          (100, true, -1);
          (200, true, -1);
        ] );
    ]
  in
  List.iter
    (fun (name, on_pane, steps) ->
      print_endline name;
      let clock = ref test_at and ms = ref 0 in
      let m = ref (model ~clock ()) in
      List.iter
        (fun (adv, run, stat) ->
          ms := !ms + adv;
          clock := test_at +. (Float.of_int !ms /. 1000.);
          let p =
            pane ~prompt:(test_at -. 1.) ~running:run ~start:test_at
              ?exit:(if stat >= 0 then Some (stat, Float.of_int (int_of_float !clock)) else None)
              "%1"
          in
          m :=
            Sidebar.track
              {
                !m with
                at = !clock;
                snap = { Sidebar.empty with panes = [ p ]; active = (if on_pane then "%1" else "") };
              };
          Printf.printf "  +%dms: %s%s\n" adv
            (indicator_name (Sidebar.shell_indicator !m (State.String_map.find "%1" !m.phases)))
            (if Sidebar.shell_pending !m then " pending" else ""))
        steps)
    cases;
  [%expect
    {|
    short command draws nothing
      +0ms: none
      +50ms: none pending
      +50ms: none pending
      +50ms: none
    long command draws running, then holds
      +0ms: none
      +100ms: none pending
      +100ms: none pending
      +100ms: running
      +700ms: running
      +100ms: running pending
      +400ms: running pending
      +100ms: none
    clean exit elsewhere replaces the green at once
      +0ms: none
      +100ms: none pending
      +300ms: running
      +100ms: done pending
      +500ms: done
    failed exit elsewhere replaces the green at once
      +0ms: none
      +100ms: none pending
      +300ms: running
      +100ms: failed pending
      +500ms: failed
    a second command inside the hold keeps the green
      +0ms: none
      +100ms: none pending
      +300ms: running
      +100ms: running pending
      +100ms: running
      +50ms: running pending
      +500ms: none
    a command after the hold starts blank again
      +0ms: none
      +100ms: none pending
      +300ms: running
      +100ms: running pending
      +600ms: none
      +100ms: none pending
      +200ms: running
    a new command keeps the outcome until it is drawn
      +0ms: none
      +100ms: none pending
      +300ms: running
      +100ms: done pending
      +600ms: done
      +100ms: done pending
      +200ms: running
    |}]

let label m p = Ui.row_text ~now:m.Sidebar.at (Row ("", Sidebar.pane_label m p))

let%expect_test "phases and latches are forgotten with their panes" =
  let m = model ~started:test_at () in
  let m =
    Sidebar.track
      {
        m with
        snap =
          {
            Sidebar.empty with
            active = "%1";
            panes = [ pane ~prompt:test_at ~running:true ~start:test_at "%1" ];
          };
      }
  in
  Printf.printf "phase recorded: %b\n" (State.String_map.mem "%1" m.phases);
  let m = Sidebar.track { m with snap = Sidebar.empty } in
  Printf.printf "phases after the pane is gone: %d\n" (State.String_map.cardinal m.phases);
  [%expect {|
    phase recorded: true
    phases after the pane is gone: 0
    |}]

(* The pane is driven through Update with a snapshot that never changes: the regression the pending
   gates exist for, since with them gone every assertion still describes a correct indicator while
   the row freezes because rebuild is never called. *)
let%expect_test "the debounce and the stall both redraw on a quiet tick" =
  let clock = ref test_at in
  let m = ref (Ui.make ~standalone:false (model ~clock ())) in
  let green () =
    Array.exists
      (fun (l : Ui.line) ->
        match l with
        | Row (_, { pane = "%1"; _ }) ->
            List.exists (fun (s : Ui.span) -> String.equal s.text "◼") (Ui.spans ~now:!clock l)
        | _ -> false)
      !m.lines
  in
  let snap running =
    let p =
      pane ~session:"alpha" ~command:"zsh" ~prompt:(test_at -. 1.) ~running ~start:test_at
        ?exit:(if running then None else Some (0, test_at))
        "%1"
    in
    { Sidebar.empty with client = client "alpha"; active = "%1"; panes = [ p ] }
  in
  let tick d running =
    clock := !clock +. d;
    m := fst (Ui.update (Snapshot (snap running)) !m);
    Printf.printf "+%.2fs %s: green=%b\n" d (if running then "running" else "stopped") (green ())
  in
  tick 0. true;
  tick Sidebar.shell_run_delay true;
  tick 1. false;
  tick (Sidebar.shell_run_hold -. 0.05) false;
  tick 0.1 false;
  let dir = temp () in
  let m =
    ref
      (Ui.make ~standalone:false
         { (model ~dir ~clock ()) with opts = { (opts ~dir ()) with threshold = 60. } })
  in
  let snap =
    {
      Sidebar.empty with
      client = client "alpha";
      active = "%1";
      panes = [ pane ~session:"alpha" ~title:"wedged" "%1" ];
      states = states [ ("%1", ("i", session ~ts:!clock "")) ];
    }
  in
  let stalled () =
    Array.exists
      (fun r -> List.exists (fun (s : Ui.span) -> String.equal s.text "!") (Ui.spans ~now:!clock r))
      !m.lines
  in
  let tick d =
    clock := !clock +. d;
    m := fst (Ui.update (Snapshot snap) !m);
    Printf.printf "+%.0fs: stalled=%b\n" d (stalled ())
  in
  tick 0.;
  tick 30.;
  tick 30.;
  [%expect
    {|
    +0.00s running: green=false
    +0.20s running: green=true
    +1.00s stopped: green=true
    +0.45s stopped: green=true
    +0.10s stopped: green=false
    +0s: stalled=false
    +30s: stalled=false
    +30s: stalled=true
    |}]

let%expect_test
    "same ignores a heartbeat's ts and catches any other change; panes compare by exclusion" =
  let snap ?(status = State.Running) ts =
    { Sidebar.empty with states = states [ ("%1", ("i", session ~status ~ts "")) ] }
  in
  Printf.printf "ts only: %b\n" (Sidebar.same (snap test_at) (snap (test_at +. 60.)));
  Printf.printf "status: %b\n" (Sidebar.same (snap test_at) (snap ~status:Idle test_at));
  let p = pane ~command:"zsh" "%1" in
  Printf.printf "window name: %b\n"
    (Sidebar.same
       { Sidebar.empty with panes = [ p ] }
       { Sidebar.empty with panes = [ { p with window_name = "x" } ] });
  Printf.printf "exit: %b\n"
    (Sidebar.same
       { Sidebar.empty with panes = [ p ] }
       { Sidebar.empty with panes = [ { p with last_exit = Some { code = 1; at = 1. } } ] });
  Printf.printf "command: %b\n"
    (Sidebar.same
       { Sidebar.empty with panes = [ p ] }
       { Sidebar.empty with panes = [ { p with current_command = "vim" } ] });
  [%expect
    {|
    ts only: true
    status: false
    window name: true
    exit: false
    command: false
    |}]

let%expect_test
    "a local integrated shell shows its command line while running, never idle or interactive" =
  let clock = ref test_at in
  let m = ref (model ~clock ()) in
  let tick p =
    m := Sidebar.track { !m with at = !clock; snap = { Sidebar.empty with panes = [ p ] } };
    print_endline (label !m p)
  in
  tick
    (pane ~command:"make" ~prompt:(test_at -. 1.) ~start:test_at ~running:true
       ~command_line:"make -j8 test" "%1");
  clock := !clock +. 1.;
  tick
    (pane ~command:"zsh" ~prompt:(test_at +. 2.) ~start:test_at
       ~exit:(0, test_at +. 1.)
       ~command_line:"make -j8 test" "%1");
  tick (pane ~command:"make" ~prompt:(test_at -. 1.) ~start:test_at ~running:true "%1");
  tick
    (pane ~command:"nvim" ~alternate:true ~prompt:(test_at -. 1.) ~start:test_at ~running:true
       ~command_line:"nvim ui.go" "%1");
  tick
    (pane ~command:"zsh" ~prompt:test_at ~start:(test_at -. 1.)
       ~exit:(0, test_at -. 1.)
       ~command_line:"make -j8 test" "%1");
  [%expect {|
     make -j8 test
    ✓zsh
    ✓make
     nvim
    ✓zsh
    |}]

let ssh_host = "deploy@build-box"

let ssh_pane ?command_line prompt start running status =
  pane ~session:"alpha" ~command:"ssh" ~pid:4242 ~prompt ~start ~running
    ?exit:(if (not running) && status >= 0 then Some (status, start +. 1.) else None)
    ?command_line "%1"

let ssh_tick clock m p =
  Sidebar.track
    {
      m with
      at = !clock;
      snap =
        {
          Sidebar.empty with
          client = client "alpha";
          panes = [ p ];
          ssh = Procs.Int_map.singleton 4242 { Procs.host = ssh_host; interactive = true };
        };
    }

let%expect_test
    "an ssh whose far side reports is drawn like any integrated shell, and one that does not stays \
     quiet" =
  let clock = ref test_at in
  let m = ref (model ~clock ()) in
  let step d p =
    clock := !clock +. d;
    m := ssh_tick clock !m p;
    Printf.printf "interactive=%b %s: %s\n" (Sidebar.interactive_pane !m p)
      (indicator_name
         (Option.flat_map (Sidebar.shell_indicator !m) (State.String_map.find_opt "%1" !m.phases)))
      (label !m p)
  in
  step 0. (ssh_pane ~command_line:("ssh " ^ ssh_host) (test_at -. 1.) test_at true (-1));
  step 1. (ssh_pane (test_at +. 1.) test_at false (-1));
  step 1. (ssh_pane ~command_line:"sleep 45" (test_at +. 1.) (test_at +. 2.) true (-1));
  step Sidebar.shell_run_delay
    (ssh_pane ~command_line:"sleep 45" (test_at +. 1.) (test_at +. 2.) true (-1));
  step 1. (ssh_pane ~command_line:"sleep 45" (test_at +. 4.) (test_at +. 2.) false 0);
  print_endline "-- no integration on the far side";
  let m = ref (model ~clock ()) in
  let p = ssh_pane test_at test_at true (-1) in
  let quiet =
    List.for_all
      (fun _ ->
        clock := !clock +. 1.;
        m := ssh_tick clock !m p;
        Sidebar.interactive_pane !m p
        && Option.is_none
             (Option.flat_map (Sidebar.shell_indicator !m)
                (State.String_map.find_opt "%1" !m.phases)))
      (List.range 1 10)
  in
  Printf.printf "quiet for ten ticks: %b\n" quiet;
  [%expect
    {|
    interactive=true none:  ssh deploy@build-box
    interactive=false none:  ssh deploy@build-box
    interactive=false none:  ssh deploy@build-box: sleep 45
    interactive=false running: ◼ssh deploy@build-box: sleep 45
    interactive=false done: ✓ssh deploy@build-box
    -- no integration on the far side
    quiet for ten ticks: true
    |}]

let%expect_test
    "the remote latch: same-second prompt, dropped with the session, forgotten with the pane" =
  let clock = ref test_at in
  let m = ref (model ~clock ()) in
  let step d p =
    clock := !clock +. d;
    m := ssh_tick clock !m p;
    Sidebar.interactive_pane !m p
  in
  let start = ssh_pane test_at test_at true (-1) in
  Printf.printf "prompt in the ssh's own second stays suppressed: %b\n"
    (step 0. start && step 0.3 start);
  ignore (step 1. (ssh_pane test_at (test_at +. 1.) true (-1)));
  Printf.printf "the prompt after the first remote command reports: %b\n"
    (not (step 1. (ssh_pane (test_at +. 2.) (test_at +. 1.) false 0)));
  let m2 = ref (model ~clock ()) in
  m2 := ssh_tick clock !m2 (ssh_pane (test_at +. 1.) test_at false (-1));
  Printf.printf "latched: %b\n" (Sidebar.ssh_remote !m2 (ssh_pane 0. 0. false (-1)));
  m2 :=
    Sidebar.track
      {
        !m2 with
        snap =
          {
            Sidebar.empty with
            client = client "alpha";
            panes = [ pane ~session:"alpha" ~command:"zsh" ~pid:4242 ~prompt:(test_at +. 2.) "%1" ];
          };
      };
  Printf.printf "dropped once the pane is a local shell: %b\n"
    (not (Sidebar.ssh_remote !m2 (ssh_pane 0. 0. false (-1))));
  let next = ssh_pane (test_at +. 2.) (test_at +. 3.) true (-1) in
  m2 := ssh_tick clock !m2 next;
  Printf.printf "a second ssh is judged afresh: %b\n" (Sidebar.interactive_pane !m2 next);
  m2 := Sidebar.track { !m2 with snap = Sidebar.empty };
  Printf.printf "forgotten with the pane: %b\n" (State.String_map.is_empty !m2.ssh_remote);
  [%expect
    {|
    prompt in the ssh's own second stays suppressed: true
    the prompt after the first remote command reports: true
    latched: true
    dropped once the pane is a local shell: true
    a second ssh is judged afresh: true
    forgotten with the pane: true
    |}]

let%expect_test
    "a program that has taken the terminal draws nothing, and leaves no hold on the way out" =
  let clock = ref test_at in
  let m = ref (model ~clock ()) in
  let warm p ssh =
    clock := test_at;
    m := { (model ~clock ()) with phases = State.String_map.empty };
    let tick () =
      m := Sidebar.track { !m with at = !clock; snap = { Sidebar.empty with panes = [ p ]; ssh } }
    in
    tick ();
    clock := !clock +. 0.5;
    tick ();
    label !m p
  in
  let p ?(alternate = false) command =
    pane ~pid:4242 ~command ~alternate ~prompt:(test_at -. 1.) ~running:true ~start:test_at "%1"
  in
  let ssh interactive = Procs.Int_map.singleton 4242 { Procs.host = "build-box"; interactive } in
  List.iter print_endline
    [
      warm (p ~alternate:true "nvim") Procs.Int_map.empty;
      warm (p ~alternate:true "git") Procs.Int_map.empty;
      warm (p "cargo") Procs.Int_map.empty;
      warm (p "ssh") (ssh true);
      warm (p "ssh") (ssh false);
      warm (p ~alternate:true "ssh") (ssh false);
    ];
  print_endline "-- an editor open, then quit";
  let m = ref (model ~clock ()) in
  let step d alternate running =
    clock := !clock +. d;
    let p = pane ~command:"nvim" ~alternate ~prompt:(test_at -. 1.) ~running ~start:test_at "%1" in
    m := Sidebar.track { !m with at = !clock; snap = { Sidebar.empty with panes = [ p ] } };
    print_endline (label !m p)
  in
  List.iter (fun d -> step d true true) [ 0.; 0.3; 1. ];
  List.iter (fun d -> step d false false) [ 0.1; 0.2; 0.4 ];
  [%expect
    {|
     nvim
     git
    ◼cargo
     ssh build-box
    ◼ssh build-box
     ssh build-box
    -- an editor open, then quit
     nvim
     nvim
     nvim
     nvim
     nvim
     nvim
    |}]

let%expect_test
    "the fuzzy filter keeps matching sessions, best first, and an agent title matches too" =
  let panes =
    [
      pane ~session:"alpha" ~window:"@1" ~command:"zsh" "%1";
      pane ~session:"beta" ~window:"@2" ~title:"π - kido" "%2";
      pane ~session:"gamma" ~window:"@3" ~command:"zsh" "%3";
    ]
  in
  let m = model () in
  let m =
    {
      m with
      snap =
        {
          Sidebar.empty with
          client = client "alpha";
          panes;
          states = states [ ("%2", ("i", session ~title:"kido" "")) ];
        };
    }
  in
  let show filter =
    Printf.printf "%S: %s\n" filter
      (String.concat " | "
         (List.map (Ui.row_text ~now:m.at) (lines { m with search = Some filter })))
  in
  show "";
  show "zz";
  show "kido";
  show "a";
  [%expect
    {|
    "": alpha | ╶ zsh | beta | ╶◼kido | gamma | ╶ zsh
    "zz":
    "kido": beta | ╶◼kido
    "a": alpha | ╶ zsh | gamma | ╶ zsh | beta | ╶◼kido
    |}]

let%expect_test "a row wider than the sidebar is cut to its width, ellipsis included" =
  let show width texts =
    let cut =
      Ui.truncate width
        (List.map (fun text -> { Ui.text; style = Mosaic.Ansi.Style.default }) texts)
    in
    let text = String.concat "" (List.map (fun (s : Ui.span) -> s.text) cut) in
    Printf.printf "%d %S -> %S\n" width (String.concat "" texts) text
  in
  show 4 [ "ab"; "cd" ];
  show 4 [ "abcd"; "ef" ];
  show 4 [ "ab"; "cd"; "e" ];
  show 4 [ "abcdef" ];
  show 4 [ "ab"; "cdef" ];
  [%expect
    {|
    4 "abcd" -> "abcd"
    4 "abcdef" -> "abc\226\128\166"
    4 "abcde" -> "abc\226\128\166"
    4 "abcdef" -> "abc\226\128\166"
    4 "abcdef" -> "abc\226\128\166"
    |}]

let%expect_test "a pause is the wall clock outrunning the monotonic one" =
  let reading wall mono_s : Sidebar.reading =
    { wall; mono = Mtime.of_uint64_ns (Int64.of_float (mono_s *. 1e9)) }
  in
  List.iter
    (fun (name, wall, mono) ->
      Printf.printf "%-26s %b\n" name
        (Sidebar.detect_pause (reading 1000. 1000.) (reading (1000. +. wall) (1000. +. mono))))
    [
      ("awake, tick on schedule", 0.1, 0.1);
      ("awake, tick genuinely slow", 300., 300.);
      ("just under the slack", 4.999, 0.);
      ("just over the slack", 5.001, 0.);
      ("asleep for minutes", 300., 0.05);
    ];
  [%expect
    {|
    awake, tick on schedule    false
    awake, tick genuinely slow false
    just under the slack       false
    just over the slack        true
    asleep for minutes         true
    |}]

(* The feed's wire format: key order, the indicator encoding (null for an empty field, idle for an
   integrated idle shell, gone with its outcome), a running bash run's start, untruncated spans with their roles, attention from
   the predicate n/N walk, and rows grouped under their own session. *)
let%expect_test "a snapshot as the feed sends it" =
  let dir = temp () in
  let id = new_run ~dir "helper" in
  ignore
    (Subrun.record_outcome ~dir
       (Result.get_exn (Subrun.parse_id id))
       { result = Failed; text = ""; at = None });
  let panes =
    [
      pane ~session:"alpha" ~window:"@1" ~title:"orchestrator" ~active:true "%1";
      pane ~session:"alpha" ~window:"@1" ~command:"bash" ~prompt:test_at "%2";
      pane ~session:"alpha" ~window:"@1" ~command:"vim" ~alternate:true "%3";
      pane ~session:"alpha" ~window:"@4" ~dead_at:1. ~run:id "%4";
      pane ~session:"alpha" ~window:"@6" ~run:(new_run ~dir ~kind:Bash "build") "%6";
    ]
    @ [ { (pane ~session:"beta" ~window:"@5" ~title:"asker" "%5") with session_id = "$1" } ]
  in
  let states =
    states
      [
        ("%1", ("root", session ~activity:"reading the contract" ""));
        ("%5", ("asker", session ~status:Waiting ""));
      ]
  in
  let m, _ =
    Sidebar.step (model ~dir ())
      {
        Sidebar.empty with
        client = client "alpha";
        active = "%1";
        panes;
        states;
        lingering = Sidebar.lingering_subagents ~dir panes State.String_map.empty;
      }
  in
  let json m = Option.get_exn_or "client" (Sidebar.to_json m) in
  print_endline (Yojson.Safe.pretty_to_string (json m));
  print_endline
    (Yojson.Safe.to_string
       (json
          (fst
             (Sidebar.step m { Sidebar.empty with client = m.snap.client; err = Some "tmux: gone" }))));
  [%expect
    {|
    {
      "v": 2,
      "client": { "session": "$0", "window": "@1", "pane": "%1" },
      "filter": "",
      "error": null,
      "sessions": [
        {
          "id": "$0",
          "name": "alpha",
          "current": true,
          "nodes": [
            {
              "kind": "window",
              "id": "@1",
              "window": "@1",
              "name": "",
              "children": [
                {
                  "kind": "agent",
                  "id": "%1",
                  "pane": "%1",
                  "window": "@1",
                  "indicator": { "kind": "running" },
                  "title": [ { "text": "orchestrator", "role": "plain" } ],
                  "tail": [ { "text": "reading the contract", "role": "dim" } ],
                  "run": null,
                  "started": null,
                  "attention": false,
                  "children": []
                },
                {
                  "kind": "shell",
                  "id": "%2",
                  "pane": "%2",
                  "window": "@1",
                  "indicator": { "kind": "idle" },
                  "title": [ { "text": "bash", "role": "proc" } ],
                  "tail": [],
                  "run": null,
                  "started": null,
                  "attention": false,
                  "children": []
                },
                {
                  "kind": "shell",
                  "id": "%3",
                  "pane": "%3",
                  "window": "@1",
                  "indicator": null,
                  "title": [ { "text": "vim", "role": "proc" } ],
                  "tail": [],
                  "run": null,
                  "started": null,
                  "attention": false,
                  "children": []
                }
              ]
            },
            {
              "kind": "agent",
              "id": "%4",
              "pane": "%4",
              "window": "@4",
              "indicator": { "kind": "gone", "outcome": "failed" },
              "title": [ { "text": "helper", "role": "dim" } ],
              "tail": [ { "text": "failed", "role": "dim" } ],
              "run": "agent",
              "started": null,
              "attention": false,
              "children": []
            },
            {
              "kind": "run",
              "id": "%6",
              "pane": "%6",
              "window": "@6",
              "indicator": { "kind": "running" },
              "title": [ { "text": "build", "role": "plain" } ],
              "tail": [],
              "run": "bash",
              "started": 1700000000.0,
              "attention": false,
              "children": []
            }
          ]
        },
        {
          "id": "$1",
          "name": "beta",
          "current": false,
          "nodes": [
            {
              "kind": "agent",
              "id": "%5",
              "pane": "%5",
              "window": "@5",
              "indicator": { "kind": "waiting" },
              "title": [ { "text": "asker", "role": "plain" } ],
              "tail": [],
              "run": null,
              "started": null,
              "attention": true,
              "children": []
            }
          ]
        }
      ]
    }
    {"v":2,"client":{"session":"$0","window":"@1","pane":"%1"},"filter":"","error":"tmux: gone","sessions":[]}
    |}]

let%expect_test "feed nodes nest a two-pane subagent window and a one-pane run" =
  let dir = temp () in
  let run = new_run ~dir ~parent:"root" ~kind:Bash "build" in
  let panes =
    [
      pane ~session:"alpha" ~window:"@1" ~active:true "%1";
      pane ~session:"alpha" ~window:"@2" "%2";
      pane ~session:"alpha" ~window:"@2" ~command:"bash" "%3";
      pane ~session:"alpha" ~window:"@3" ~run "%4";
    ]
  in
  let states =
    states
      [
        ("%1", ("root", session ~title:"root" ""));
        ("%2", ("kid", session ~parent:"root" ~title:"kid" ""));
      ]
  in
  let m, _ =
    Sidebar.step (model ~dir ())
      {
        Sidebar.empty with
        client = client "alpha";
        active = "%1";
        panes;
        states;
        lingering = Sidebar.lingering_subagents ~dir panes State.String_map.empty;
      }
  in
  print_endline (Yojson.Safe.pretty_to_string (Option.get_exn_or "client" (Sidebar.to_json m)));
  [%expect
    {|
    {
      "v": 2,
      "client": { "session": "$0", "window": "@1", "pane": "%1" },
      "filter": "",
      "error": null,
      "sessions": [
        {
          "id": "$0",
          "name": "alpha",
          "current": true,
          "nodes": [
            {
              "kind": "agent",
              "id": "%1",
              "pane": "%1",
              "window": "@1",
              "indicator": { "kind": "running" },
              "title": [ { "text": "root", "role": "plain" } ],
              "tail": [],
              "run": null,
              "started": null,
              "attention": false,
              "children": [
                {
                  "kind": "window",
                  "id": "@2",
                  "window": "@2",
                  "name": "",
                  "children": [
                    {
                      "kind": "agent",
                      "id": "%2",
                      "pane": "%2",
                      "window": "@2",
                      "indicator": { "kind": "running" },
                      "title": [ { "text": "kid", "role": "plain" } ],
                      "tail": [],
                      "run": null,
                      "started": null,
                      "attention": false,
                      "children": []
                    },
                    {
                      "kind": "shell",
                      "id": "%3",
                      "pane": "%3",
                      "window": "@2",
                      "indicator": null,
                      "title": [ { "text": "bash", "role": "proc" } ],
                      "tail": [],
                      "run": null,
                      "started": null,
                      "attention": false,
                      "children": []
                    }
                  ]
                },
                {
                  "kind": "run",
                  "id": "%4",
                  "pane": "%4",
                  "window": "@3",
                  "indicator": { "kind": "running" },
                  "title": [ { "text": "build", "role": "plain" } ],
                  "tail": [],
                  "run": "bash",
                  "started": 1700000000.0,
                  "attention": false,
                  "children": []
                }
              ]
            }
          ]
        }
      ]
    }
    |}]

let%expect_test "every role names its foreground" =
  List.iter
    (fun r -> Format.printf "%a@." Mosaic.Ansi.Style.pp (Ui.style r))
    [ `Plain; `Current; `Proc; `Dim; `Err; `Running; `Waiting; `Compacting; `Done; `Stalled ];
  [%expect
    {|
    Style{fg=#000000}
    Style{fg=#000000, attrs=[Bold]}
    Style{fg=#c0c0c0}
    Style{fg=#808080}
    Style{fg=#800000}
    Style{fg=#008000}
    Style{fg=#808000, attrs=[Bold]}
    Style{fg=#800080}
    Style{fg=#008000, attrs=[Bold]}
    Style{fg=#800000, attrs=[Bold]}
    |}]
