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
  }

let pane ?ssh ?(session = "sess") ?(window = "@1") ?(command = "") ?(title = "") ?(pid = 0) ?run
    ?dead_at ?(alternate = false) ?(running = false) ?start ?prompt ?exit ?(command_line = "")
    ?(active = false) pane_id : Tmux.Pane.t =
  {
    session_name = session;
    session_id = Option.get_exn_or "id" (Tmux.Session.of_string "$0");
    session_created = 0.;
    window_index = 0;
    window_id = Option.get_exn_or "id" (Tmux.Window.of_string window);
    window_name = "";
    window_layout = "";
    pane_id = Option.get_exn_or "id" (Tmux.Pane.of_string pane_id);
    active;
    pane_active = active;
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
    ssh;
    session_attached = active;
    program_status = { serial = 0; records = [] };
    title;
  }

let agent_pane ?run w p title = pane ~window:w ~title ?run p
let shell_pane w p = pane ~window:w ~command:"zsh" p

let session ?(agent = State.Pi) ?(parent = "") ?(depth = 0) ?(ts = test_at) ?(activity = "") pane :
    State.session =
  {
    agent;
    name = "";
    pane = Tmux.Pane.of_string pane;
    pid = Unix.getpid ();
    ts;
    inbox = "";
    activity;
    parent = (if String.is_empty parent then None else Some { State.session = parent; pid = 0 });
    depth;
    model = "";
  }

let agent_state id parent = (id, session ~parent "")

let states l =
  List.fold_left
    (fun m (pane, (id, s)) ->
      let pane = Option.get_exn_or "id" (Tmux.Pane.of_string pane) in
      Tmux.Pane.Map.add pane (id, { s with State.pane = Some pane }) m)
    Tmux.Pane.Map.empty l

let with_programs states panes =
  List.map
    (fun (p : Tmux.Pane.t) ->
      if Tmux.Pane.Map.mem p.pane_id states then
        {
          p with
          program_status =
            Result.get_exn
              (Tmux.Program_status.parse
                 {|{"serial":1,"records":[{"id":"","app":"pi","state":"working"}]}|});
        }
      else p)
    panes

let model ?(dir = temp ()) ?(clock = ref test_at) ?(started = test_at -. 3600.) () =
  let m = Sidebar.make ~now:(fun () -> !clock) (opts ~dir ()) in
  { m with started; at = !clock }

let pane_label (m : Sidebar.model) p =
  let p =
    match Tmux.Pane.find m.snap.panes p.Tmux.Pane.pane_id with
    | Some current -> { p with program_status = current.program_status }
    | None -> p
  in
  Sidebar.pane_label m (p, State.pane_kind ~states:m.snap.states p)

let client session =
  Some
    {
      Tmux.Exec.session;
      session_id = Option.get_exn_or "id" (Tmux.Session.of_string "$0");
      focused = false;
    }

let lines m = Array.to_list (Ui.lines (Sidebar.rebuild (Sidebar.classify m)))

let render ?dir ?(current = "sess") ?(at = test_at) panes st =
  let m = model ?dir ~clock:(ref at) () in
  let states = states st in
  let snap =
    {
      Sidebar.empty with
      client = client current;
      panes = with_programs states panes;
      states;
      lingering = Sidebar.lingering_subagents ~dir:m.opts.dir panes Sidebar.String_map.empty;
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
    [ ("%22", agent_state "root-sess" ""); ("%30", agent_state "kid-sess" "root-sess") ];
  [%expect {|
    sess
    ┌◼orchestrator
    │ └◼subagent
    └ zsh
    |}]

let%expect_test "field() keeps the three cases aligned" =
  render
    [ agent_pane "@1" "%1" "orchestrator"; pane ~title:"idle-agent" "%2"; shell_pane "@1" "%3" ]
    [ ("%1", agent_state "root-sess" ""); ("%2", ("idle-sess", session "")) ];
  [%expect {|
    sess
    ┌◼orchestrator
    ├◼idle-agent
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
      ("%22", agent_state "root-sess" "");
      ("%30", agent_state "kid-a-sess" "root-sess");
      ("%31", agent_state "kid-b-sess" "root-sess");
      ("%32", agent_state "kid-c-sess" "root-sess");
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
      ("%22", agent_state "root-sess" "");
      ("%30", agent_state "kid-a-sess" "root-sess");
      ("%31", agent_state "kid-b-sess" "root-sess");
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
      ("%1", agent_state "root-sess" "");
      ("%2", agent_state "a-sess" "root-sess");
      ("%3", agent_state "b-sess" "root-sess");
      ("%4", agent_state "a1-sess" "a-sess");
      ("%5", agent_state "b1-sess" "b-sess");
      ("%6", agent_state "b2-sess" "b-sess");
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
    [ ("%1", agent_state "first-sess" ""); ("%2", agent_state "second-sess" "") ];
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
    [ ("%22", agent_state "root-sess" ""); ("%30", agent_state "kid-sess" "root-sess") ];
  render
    [
      shell_pane "@13" "%10";
      agent_pane "@13" "%22" "orchestrator";
      agent_pane "@20" "%30" "subagent";
    ]
    [ ("%22", agent_state "root-sess" ""); ("%30", agent_state "kid-sess" "root-sess") ];
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
      ("%1", agent_state "root-sess" "");
      ("%2", ("kid-sess", session ~parent:"root-sess" ~depth:1 ""));
      ("%3", ("gk-sess", session ~parent:"kid-sess" ~depth:1 ""));
    ];
  render
    [ agent_pane "@1" "%1" "unrelated"; agent_pane "@2" "%2" "orphan" ]
    [
      ("%1", agent_state "other-sess" "");
      ("%2", ("orphan-sess", session ~parent:"elsewhere-sess" ~depth:1 ""));
    ];
  render
    [ agent_pane "@1" "%207" "a"; agent_pane "@2" "%208" "b" ]
    [ ("%207", agent_state "a-sess" "b-sess"); ("%208", agent_state "b-sess" "a-sess") ];
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
      ("%1", agent_state "root-sess" "");
      ("%3", agent_state "a-sess" "root-sess");
      ("%4", agent_state "b-sess" "root-sess");
      ("%5", agent_state "g-sess" "b-sess");
    ]
  in
  let rows () =
    let m = model () in
    let states = states st in
    lines
      {
        m with
        snap =
          { Sidebar.empty with client = client "sess"; panes = with_programs states panes; states };
      }
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
      Printf.printf "%s anchor=%s\n"
        (Tmux.Window.to_string (List.hd pl.panes).window_id)
        (Option.map_or ~default:"-" Tmux.Pane.to_string pl.anchor))
    (Sidebar.order_windows_by_tree windows (states st) lingering)

let w ?run id = [ pane ~window:("@" ^ id) ?run ("%" ^ id) ]

let%expect_test "order_windows_by_tree: child after parent, anchored to the parent's pane" =
  placements
    [ w "200"; w "201"; w "203"; w "202" ]
    [
      ("%201", ("root-sess", session ""));
      ("%203", ("", session ~parent:"root-sess" ~depth:1 ""));
      ("%202", ("", session ~parent:"root-sess" ~depth:1 ""));
    ]
    Sidebar.String_map.empty;
  placements
    [ w "200"; w "204" ]
    [ ("%204", ("orphan-sess", session ~parent:"elsewhere-sess" ~depth:1 "")) ]
    Sidebar.String_map.empty;
  placements
    [ w "201"; w "205"; w "206" ]
    [
      ("%201", ("root-sess", session ""));
      ("%205", ("kid-sess", session ~parent:"root-sess" ~depth:1 ""));
      ("%206", ("gk-sess", session ~parent:"kid-sess" ~depth:1 ""));
    ]
    Sidebar.String_map.empty;
  placements
    [ w "207"; w "208" ]
    [
      ("%207", ("a-sess", session ~parent:"b-sess" ""));
      ("%208", ("b-sess", session ~parent:"a-sess" ""));
    ]
    Sidebar.String_map.empty;
  [%expect
    {|
    @200 anchor=-
    @201 anchor=-
    @203 anchor=%201
    @202 anchor=%201
    @200 anchor=-
    @204 anchor=-
    @201 anchor=-
    @205 anchor=%201
    @206 anchor=%205
    @207 anchor=-
    @208 anchor=%207
    |}]

let%expect_test "order_windows_by_tree: the lingering fallback, and a record beating a stale mark" =
  let lingering parent =
    Sidebar.String_map.singleton "run-1"
      { Sidebar.stamp = None; name = ""; parent; outcome = None; kind = Agent; started = test_at }
  in
  placements
    [ w "201"; w ~run:"run-1" "205" ]
    [ ("%201", ("root-sess", session "")) ]
    (lingering "root-sess");
  placements
    [ w "201"; w "209"; w ~run:"run-1" "205" ]
    [
      ("%201", ("root-sess", session ""));
      ("%209", ("other-sess", session ""));
      ("%205", ("kid-sess", session ~parent:"root-sess" ""));
    ]
    (lingering "other-sess");
  placements [ w "200"; w ~run:"run-1" "205" ] [] (lingering "elsewhere-sess");
  placements [ w ~run:"run-1" "205" ] [] (lingering "nonexistent-sess");
  placements
    [ [ pane ~window:"@13" "%21"; pane ~window:"@13" "%101" ]; w "210"; w "211" ]
    [
      ("%21", ("top-sess", session ""));
      ("%101", ("second-sess", session ""));
      ("%210", ("kid1-sess", session ~parent:"top-sess" ~depth:1 ""));
      ("%211", ("kid2-sess", session ~parent:"second-sess" ~depth:1 ""));
    ]
    Sidebar.String_map.empty;
  [%expect
    {|
    @201 anchor=-
    @205 anchor=%201
    @201 anchor=-
    @205 anchor=%201
    @209 anchor=-
    @200 anchor=-
    @205 anchor=-
    @205 anchor=-
    @13 anchor=-
    @210 anchor=%21
    @211 anchor=%101
    |}]

let%expect_test "window targets: siblings precede parents, next leaves the root subtree" =
  let windows =
    Sidebar.windows_in_order
      (List.concat
         [
           w "201"; w "209"; w ~run:"child1" "202"; w ~run:"child2" "203"; w ~run:"grandchild" "212";
         ])
      (states
         [
           ("%201", ("root-session", session ""));
           ("%202", ("child1-session", session ~parent:"root-session" ""));
           ("%203", ("child2-session", session ~parent:"root-session" ""));
           ("%212", ("grandchild-session", session ~parent:"child2-session" ""));
         ])
      Sidebar.String_map.empty
  in
  List.iter
    (fun (next, window) ->
      Printf.printf "%s %s -> %s\n"
        (if next then "next" else "prev")
        window
        (Option.map_or ~default:"-"
           (fun (p : Tmux.Pane.t) -> Tmux.Window.to_string p.window_id)
           (Tmux.Exec.window_target ~next
              ~session:(Option.get_exn_or "id" (Tmux.Session.of_string "$0"))
              ~window:
                (Option.get_exn_or "id"
                   (Tmux.Window.of_string
                      ("@"
                      ^ List.assoc ~eq:String.equal window
                          [
                            ("other", "209");
                            ("root", "201");
                            ("child2", "203");
                            ("grandchild", "212");
                          ])))
              windows)))
    [
      (false, "other");
      (false, "root");
      (false, "child2");
      (false, "grandchild");
      (true, "child2");
      (true, "root");
    ];
  [%expect
    {|
    prev other -> @201
    prev root -> @209
    prev child2 -> @202
    prev grandchild -> @203
    next child2 -> @209
    next root -> @209
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
      pane = None;
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
  [%expect
    {|
    sess
    ╶◼helper 1m05s
    sess
    ╶◼helper checking tests
    sess
    ╶◼helper 1m05s
    |}]

let%expect_test "run metadata survives activity text and clears its clock on death or outcome" =
  let p = agent_pane ~run:"run" "@20" "%30" "helper" in
  let m =
    {
      (model ()) with
      snap =
        {
          Sidebar.empty with
          states = states [ ("%30", ("run", session ~activity:"checking tests" "")) ];
          panes = with_programs (states [ ("%30", ("run", session "")) ]) [ p ];
          lingering =
            Sidebar.String_map.singleton "run"
              {
                Sidebar.stamp = None;
                name = "helper";
                parent = "";
                outcome = None;
                kind = Agent;
                started = test_at;
              };
        };
    }
  in
  List.iter
    (fun (p, outcome) ->
      let lingering =
        Sidebar.String_map.map (fun (l : Sidebar.lingering) -> { l with outcome }) m.snap.lingering
      in
      let row = pane_label { m with snap = { m.snap with lingering } } p in
      match row.run with
      | None -> print_endline "no run"
      | Some run ->
          Printf.printf "%s %s %s\n" (Subrun.string_of_kind run.kind)
            (Option.map_or ~default:"-" (fun _ -> "started") run.started)
            (Ui.row_text ~now:test_at
               (Ui.Row ("", Option.get_exn_or "id" (Tmux.Session.of_string "$0"), row))))
    [ (p, None); ({ p with dead_at = Some 1. }, None); (p, Some Completed) ];
  [%expect
    {|
    agent started ◼helper checking tests
    agent - ×helper
    agent - ✓helper completed
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
          lingering = Sidebar.lingering_subagents ~dir panes Sidebar.String_map.empty;
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
    [ ("%22", agent_state "root-sess" "") ];
  render
    [
      agent_pane "@13" "%22" "working-on-kido";
      shell_pane "@20" "%5";
      agent_pane ~run:"run-1" "@20" "%4" "helper";
    ]
    [ ("%22", agent_state "root-sess" ""); ("%4", ("helper-sess", session ~parent:"root-sess" "")) ];
  render
    [
      agent_pane "@13" "%21" "top-level";
      agent_pane "@13" "%101" "second";
      agent_pane "@20" "%30" "subagent-b";
    ]
    [
      ("%21", agent_state "top-sess" "");
      ("%101", agent_state "second-sess" "");
      ("%30", agent_state "kid-sess" "second-sess");
    ];
  [%expect
    {|
    sess
    ╶◼orchestrator
      └×subagent
    sess
    ╶◼working-on-kido
      └┌◼helper
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
  let first = Sidebar.lingering_subagents ~dir panes Sidebar.String_map.empty in
  let show l =
    let (l : Sidebar.lingering) = Sidebar.String_map.find id l in
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

let%expect_test "pane_title" =
  let st = states [ ("%1", ("agent", session "%1")) ] in
  List.iter
    (fun title ->
      Printf.printf "%s -> %s\n" title
        (Option.value ~default:"(not an agent)"
           (let p = List.hd (with_programs st [ pane ~title "%1" ]) in
            State.pane_title p (State.pane_kind ~states:st p))))
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
    ✳ Tmux config -> ✳ Tmux config
    ✳ 2 panes -> ✳ 2 panes
    π - kido - kido -> π - kido - kido
    π - kido -> π - kido
    π -  -> π -
    plain title -> plain title
    π-no-space -> π-no-space
     ->
    ✳  -> ✳
    ~/src/kido -> ~/src/kido
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
  show "no integration" (m Tmux.Pane.Map.empty) (pane ~exit:(1, ended) "%1");
  show "running" (m Tmux.Pane.Map.empty)
    (integrated ~running:true ~start:(ended +. 1.) ~exit:(1, ended) ());
  show "clean exit, not yet visited" (m Tmux.Pane.Map.empty) (integrated ~exit:(0, ended) ());
  show "nonzero exit, not yet visited" (m Tmux.Pane.Map.empty) (integrated ~exit:(1, ended) ());
  show "nonzero exit, pane visited since"
    (m (Tmux.Pane.Map.singleton (Option.get_exn_or "id" (Tmux.Pane.of_string "%1")) visited))
    (integrated ~exit:(1, ended) ());
  show "no status on record" (m Tmux.Pane.Map.empty) (integrated ());
  show "no command has run" (m Tmux.Pane.Map.empty) (pane ~prompt:ended ~exit:(0, ended) "%1");
  show "no end time" (m Tmux.Pane.Map.empty) (integrated ~exit:(1, 0.) ());
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
                snap =
                  {
                    Sidebar.empty with
                    panes = [ p ];
                    active = (if on_pane then Tmux.Pane.of_string "%1" else None);
                  };
              };
          Printf.printf "  +%dms: %s%s\n" adv
            (indicator_name
               (Sidebar.shell_indicator !m
                  (Tmux.Pane.Map.find (Option.get_exn_or "id" (Tmux.Pane.of_string "%1")) !m.phases)))
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

let label m (p : Tmux.Pane.t) =
  Ui.row_text ~now:m.Sidebar.at (Row ("", p.session_id, pane_label m p))

let%expect_test "phases and latches are forgotten with their panes" =
  let m = model ~started:test_at () in
  let m =
    Sidebar.track
      {
        m with
        snap =
          {
            Sidebar.empty with
            active = Tmux.Pane.of_string "%1";
            panes = [ pane ~prompt:test_at ~running:true ~start:test_at "%1" ];
          };
      }
  in
  Printf.printf "phase recorded: %b\n"
    (Tmux.Pane.Map.mem (Option.get_exn_or "id" (Tmux.Pane.of_string "%1")) m.phases);
  let m = Sidebar.track { m with snap = Sidebar.empty } in
  Printf.printf "phases after the pane is gone: %d\n" (Tmux.Pane.Map.cardinal m.phases);
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
        | Row (_, _, { pane; _ })
          when Tmux.Pane.equal pane (Option.get_exn_or "id" (Tmux.Pane.of_string "%1")) ->
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
    { Sidebar.empty with client = client "alpha"; active = Tmux.Pane.of_string "%1"; panes = [ p ] }
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
      active = Tmux.Pane.of_string "%1";
      panes =
        with_programs
          (states [ ("%1", ("i", session ~ts:!clock "")) ])
          [ pane ~session:"alpha" ~title:"wedged" "%1" ];
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
  let snap ts =
    { Sidebar.empty with panes = [ pane "%1" ]; states = states [ ("%1", ("i", session ~ts "")) ] }
  in
  Printf.printf "ts only: %b\n" (Sidebar.same (snap test_at) (snap (test_at +. 60.)));
  Printf.printf "status: %b\n"
    (Sidebar.same (snap test_at)
       { (snap test_at) with panes = with_programs (snap test_at).states (snap test_at).panes });
  let p = pane ~command:"zsh" "%1" in
  Printf.printf "layout: %b\n"
    (Sidebar.same
       { Sidebar.empty with panes = [ p ] }
       { Sidebar.empty with panes = [ { p with window_layout = "x" } ] });
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
    layout: true
    window name: false
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
  pane ~ssh:("deploy", "build-box") ~session:"alpha" ~command:"ssh" ~pid:4242 ~prompt ~start
    ~running
    ?exit:(if (not running) && status >= 0 then Some (status, start +. 1.) else None)
    ?command_line "%1"

let ssh_tick clock m p =
  Sidebar.track
    { m with at = !clock; snap = { Sidebar.empty with client = client "alpha"; panes = [ p ] } }

let%expect_test "an ssh runs until a remote prompt, then follows the remote shell" =
  let clock = ref test_at in
  let m = ref (model ~clock ()) in
  let step d p =
    clock := !clock +. d;
    m := ssh_tick clock !m p;
    Printf.printf "remote=%b %s: %s\n" (Sidebar.ssh_remote !m p)
      (indicator_name
         (Option.flat_map (Sidebar.shell_indicator !m)
            (Tmux.Pane.Map.find_opt (Option.get_exn_or "id" (Tmux.Pane.of_string "%1")) !m.phases)))
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
  m := ssh_tick clock !m p;
  let running =
    List.for_all
      (fun _ ->
        clock := !clock +. 1.;
        m := ssh_tick clock !m p;
        (not (Sidebar.ssh_remote !m p))
        && Option.exists
             (function Sidebar.Status State.Running -> true | _ -> false)
             (Option.flat_map (Sidebar.shell_indicator !m)
                (Tmux.Pane.Map.find_opt
                   (Option.get_exn_or "id" (Tmux.Pane.of_string "%1"))
                   !m.phases)))
      (List.range 1 10)
  in
  Printf.printf "running for ten ticks: %b\n" running;
  [%expect
    {|
    remote=false none:  ssh deploy@build-box
    remote=true none:  ssh deploy@build-box
    remote=true none:  ssh deploy@build-box: sleep 45
    remote=true running: ◼ssh deploy@build-box: sleep 45
    remote=true done: ✓ssh deploy@build-box
    -- no integration on the far side
    running for ten ticks: true
    |}]

let%expect_test
    "the remote latch: same-second prompt, dropped with the session, forgotten with the pane" =
  let clock = ref test_at in
  let m = ref (model ~clock ()) in
  let step d p =
    clock := !clock +. d;
    m := ssh_tick clock !m p;
    not (Sidebar.ssh_remote !m p)
  in
  let start = ssh_pane test_at test_at true (-1) in
  Printf.printf "prompt in the ssh's own second stays running: %b\n"
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
  Printf.printf "a second ssh is judged afresh: %b\n" (not (Sidebar.ssh_remote !m2 next));
  m2 := Sidebar.track { !m2 with snap = Sidebar.empty };
  Printf.printf "forgotten with the pane: %b\n" (Tmux.Pane.Map.is_empty !m2.ssh_remote);
  [%expect
    {|
    prompt in the ssh's own second stays running: true
    the prompt after the first remote command reports: true
    latched: true
    dropped once the pane is a local shell: true
    a second ssh is judged afresh: true
    forgotten with the pane: true
    |}]

let%expect_test "a new ssh destination drops the remote latch without a local-shell tick" =
  let clock = ref test_at in
  let m = ssh_tick clock (model ~clock ()) (ssh_pane (test_at +. 1.) test_at false (-1)) in
  let p =
    {
      (ssh_pane ~command_line:"ssh alias" (test_at +. 1.) (test_at +. 2.) true (-1)) with
      ssh = Some ("deploy@realm", "next.test");
    }
  in
  let m = ssh_tick clock m p in
  Printf.printf "remote=%b\n" (Sidebar.ssh_remote m p);
  Printf.printf "%s\n" (label m p);
  [%expect {|
    remote=false
     ssh deploy@realm@next.test
    |}]

let%expect_test
    "a program that has taken the terminal draws nothing, and leaves no hold on the way out" =
  let clock = ref test_at in
  let m = ref (model ~clock ()) in
  let warm p =
    clock := test_at;
    m := { (model ~clock ()) with phases = Tmux.Pane.Map.empty };
    let tick () =
      m := Sidebar.track { !m with at = !clock; snap = { Sidebar.empty with panes = [ p ] } }
    in
    tick ();
    clock := !clock +. 0.5;
    tick ();
    label !m p
  in
  let p ?(alternate = false) command =
    pane ~pid:4242 ~command ~alternate ~prompt:(test_at -. 1.) ~running:true ~start:test_at "%1"
  in
  List.iter print_endline
    [
      warm (p ~alternate:true "nvim");
      warm (p ~alternate:true "git");
      warm (p "cargo");
      warm { (p "ssh") with ssh = Some ("deploy", "build-box") };
      warm (p "ssh");
      warm { (p ~alternate:true "ssh") with ssh = Some ("deploy", "build-box") };
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
    ◼ssh deploy@build-box
    ◼ssh
     ssh deploy@build-box
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
          panes = with_programs (states [ ("%2", ("i", session "")) ]) panes;
          states = states [ ("%2", ("i", session "")) ];
        };
    }
  in
  let show filter =
    Printf.printf "%S: %s\n" filter
      (String.concat " | "
         (List.map (Ui.row_text ~now:m.at)
            (Array.to_list (Ui.lines ~search:filter (Sidebar.rebuild (Sidebar.classify m))))))
  in
  show "";
  show "zz";
  show "kido";
  show "a";
  [%expect
    {|
    "": alpha | ╶ zsh | beta | ╶◼π - kido | gamma | ╶ zsh
    "zz":
    "kido": beta | ╶◼π - kido
    "a": alpha | ╶ zsh | gamma | ╶ zsh | beta | ╶◼π - kido
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
    @ [
        {
          (pane ~session:"beta" ~window:"@5" ~title:"asker" "%5") with
          session_id = Option.get_exn_or "id" (Tmux.Session.of_string "$1");
        };
      ]
  in
  let states =
    states
      [
        ("%1", ("root", session ~activity:"reading the contract" "")); ("%5", ("asker", session ""));
      ]
  in
  let m, _ =
    Sidebar.step (model ~dir ())
      {
        Sidebar.empty with
        client = client "alpha";
        active = Tmux.Pane.of_string "%1";
        panes = with_programs states panes;
        states;
        lingering = Sidebar.lingering_subagents ~dir panes Sidebar.String_map.empty;
      }
  in
  let json m = Option.get_exn_or "client" (Protocol.snapshot m) in
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
      "asks": [],
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
                  "program_status": {
                    "serial": 1,
                    "records": [ { "id": "", "state": "working", "app": "pi" } ]
                  },
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
                  "program_status": { "serial": 0, "records": [] },
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
                  "program_status": { "serial": 0, "records": [] },
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
              "program_status": { "serial": 0, "records": [] },
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
              "program_status": { "serial": 0, "records": [] },
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
              "indicator": { "kind": "running" },
              "program_status": {
                "serial": 1,
                "records": [ { "id": "", "state": "working", "app": "pi" } ]
              },
              "title": [ { "text": "asker", "role": "plain" } ],
              "tail": [],
              "run": null,
              "started": null,
              "attention": false,
              "children": []
            }
          ]
        }
      ]
    }
    {"v":2,"client":{"session":"$0","window":"@1","pane":"%1"},"asks":[],"error":"tmux: gone","sessions":[]}
    |}]

let%expect_test "feed nodes nest a two-pane subagent window and a one-pane run" =
  let dir = temp () in
  let run = new_run ~dir ~parent:"root" ~kind:Bash "build" in
  let panes =
    [
      pane ~session:"alpha" ~window:"@1" ~title:"root" ~active:true "%1";
      pane ~session:"alpha" ~window:"@2" ~title:"kid" "%2";
      pane ~session:"alpha" ~window:"@2" ~command:"bash" "%3";
      pane ~session:"alpha" ~window:"@3" ~run "%4";
    ]
  in
  let states =
    states [ ("%1", ("root", session "")); ("%2", ("kid", session ~parent:"root" "")) ]
  in
  let panes = with_programs states panes in
  let m, _ =
    Sidebar.step (model ~dir ())
      {
        Sidebar.empty with
        client = client "alpha";
        active = Tmux.Pane.of_string "%1";
        panes;
        states;
        lingering = Sidebar.lingering_subagents ~dir panes Sidebar.String_map.empty;
      }
  in
  print_endline (Yojson.Safe.pretty_to_string (Option.get_exn_or "client" (Protocol.snapshot m)));
  [%expect
    {|
    {
      "v": 2,
      "client": { "session": "$0", "window": "@1", "pane": "%1" },
      "asks": [],
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
              "program_status": {
                "serial": 1,
                "records": [ { "id": "", "state": "working", "app": "pi" } ]
              },
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
                      "program_status": {
                        "serial": 1,
                        "records": [
                          { "id": "", "state": "working", "app": "pi" }
                        ]
                      },
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
                      "program_status": { "serial": 0, "records": [] },
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
                  "program_status": { "serial": 0, "records": [] },
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

let%expect_test "program acknowledgement survives failed snapshots and reconnects" =
  let p = pane ~command:"sh" "%7" in
  let status =
    Tmux.Program_status.parse {|{"serial":1,"records":[{"id":"","state":"done","title":"QQ"}]}|}
    |> Result.get_or_failwith
  in
  let snap = { Sidebar.empty with panes = [ { p with program_status = status } ] } in
  ignore
    (List.fold_left
       (fun m (label, snap) ->
         let m, _ = Sidebar.step m snap in
         let indicator =
           match (pane_label m p).indicator with
           | Some Sidebar.Done -> "done"
           | Some (Status Idle) -> "idle"
           | _ -> "none"
         in
         Printf.printf "%s: %s acknowledged=%b\n" label indicator
           (Tmux.Pane.Map.mem p.pane_id m.program_seen);
         m)
       (model ())
       [
         ("initial", snap);
         ("visit", { snap with active = Some p.pane_id });
         ("leave", snap);
         ("failure", { Sidebar.empty with err = Some "disconnected" });
         ("reconnect", snap);
         ( "new serial",
           { snap with panes = [ { p with program_status = { status with serial = 2 } } ] } );
       ]);
  [%expect
    {|
    initial: done acknowledged=false
    visit: idle acknowledged=true
    leave: idle acknowledged=true
    failure: none acknowledged=true
    reconnect: idle acknowledged=true
    new serial: done acknowledged=true
    |}]

let%expect_test "every role names its foreground" =
  List.iter
    (fun r -> Format.printf "%a@." Mosaic.Ansi.Style.pp (Ui.style r))
    [ `Plain; `Current; `Proc; `Dim; `Err; `Running; `Waiting; `Done; `Stalled ];
  [%expect
    {|
    Style{fg=#000000}
    Style{fg=#000000, attrs=[Bold]}
    Style{fg=#c0c0c0}
    Style{fg=#808080}
    Style{fg=#800000}
    Style{fg=#008000}
    Style{fg=#808000, attrs=[Bold]}
    Style{fg=#008000, attrs=[Bold]}
    Style{fg=#800000, attrs=[Bold]}
    |}]
