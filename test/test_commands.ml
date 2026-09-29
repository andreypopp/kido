open Kido
open Fixture

let record ~dir id s = Result.get_exn (State.record ~dir id s)
let attempt f = match f () with _ -> () | exception Failure m -> print_endline m

(* The record is full of fields a rebuilt one would lose; only the activity may change. *)
let%expect_test "set_status replaces only the activity, flattened to one line; empty clears" =
  let dir = Filename.temp_dir "kido-state" "" in
  let before =
    {
      (session ~pane:"%7" ~title:"worker" ~inbox:"/tmp/nope.sock" ~background:true ~parent:"p"
         ~depth:1 Running)
      with
      ended = Some 1_709_294_400.;
      activity = "the old one";
      model = "claude-sonnet-5";
    }
  in
  record ~dir "worker-session" before;
  List.iter
    (fun activity ->
      attempt (fun () -> Set_status.set_status ~dir ~self:"%7" activity);
      let after = Option.get_exn_or "record" (State.get ~dir "worker-session") in
      Printf.printf "%S rest unchanged: %b\n" after.activity
        (Stdlib.( = ) { after with activity = before.activity } before))
    [ "refactoring internal/ui"; "two\nlines\tand more"; "" ];
  attempt (fun () -> Set_status.set_status ~dir ~self:"%8" "busy");
  [%expect
    {|
    "refactoring internal/ui" rest unchanged: true
    "two lines and more" rest unchanged: true
    "" rest unchanged: true
    no agent session has reported pane "%8"; there is nothing to set an activity on
    |}]

(* A second live agent on the parent's pane wins it in the per-pane view; agent-alive reads the
   live list, which drops nothing. *)
let%expect_test "agent-alive: a pane collision, a dead or unknown session, and a usage error" =
  let dir = Filename.temp_dir "kido-state" "" in
  record ~dir "parent" (session ~pane:"%p" ~ts:1000. Idle);
  record ~dir "intruder" (session ~pane:"%p" ~ts:1001. Idle);
  record ~dir "dead-sess" (session ~pane:"%9" ~pid:(dead_pid ()) Idle);
  Printf.printf "per-pane view holds %s\n"
    (fst (State.Panes.find "%p" (State.by_pane (State.load_live ~dir))));
  List.iter
    (fun s -> attempt (fun () -> Agent_alive.agent_alive ~dir s))
    [ "parent"; "dead-sess"; "never-existed"; "" ];
  [%expect
    {|
    per-pane view holds intruder
    true
    false
    false
    usage: kido agent-alive SESSION
    |}]

let%expect_test "children-alive: only this parent's runs that have not ended" =
  let dir = Filename.temp_dir "kido-state" "" in
  let runs = Filename.concat dir "runs" in
  let child id parent pid =
    let id = Result.get_exn (Subrun.parse_id id) in
    Subrun.create ~dir:runs id "do a thing";
    Subrun.write_meta ~dir:runs
      {
        id;
        name = Subrun.string_of_id id;
        kind = None;
        parent_session = parent;
        depth = 1;
        pane = "";
        pid;
        cwd = "";
        model = "";
        tools = [];
        keep_alive = false;
        started_at = 0.;
      };
    id
  in
  let ask () = attempt (fun () -> Agent_alive.children_alive ~dir "parent-sess") in
  ask ();
  let live = child "run-live" "parent-sess" (Unix.getpid ()) in
  ask ();
  ignore (Subrun.record_outcome ~dir:runs live { result = Completed; text = ""; at = None });
  ask ();
  ignore (child "run-other" "other-sess" (Unix.getpid ()));
  ask ();
  ignore (child "run-gone" "parent-sess" 0);
  ask ();
  attempt (fun () -> Agent_alive.children_alive ~dir "");
  [%expect
    {|
    false
    true
    false
    false
    false
    usage: kido children-alive SESSION
    |}]

let%expect_test "snapshot: a record resumes its session; a pane's command is only a fallback" =
  let states l = State.by_pane l in
  List.iter
    (fun (p, st, pi) ->
      Printf.printf "[%s]\n" (Snapshot.pane_command p (states st) ~pi:(Procs.Int_set.of_list pi)))
    [
      (pane ~pid:1 ~cmd:"claude" "%1", [ ("sess-1", session ~agent:Claude ~pane:"%1" Idle) ], []);
      (pane ~pid:1 ~cmd:"claude" "%1", [], []);
      (pane ~pid:2 ~cmd:"node" "%2", [ ("pi-sess-1", session ~pane:"%2" Idle) ], []);
      (pane ~pid:2 ~cmd:"node" "%2", [], [ 2 ]);
      (pane ~pid:3 ~cmd:"zsh" "%3", [], []);
      ( pane ~pid:2 ~cmd:"node" "%2",
        [ ("other-1", session ~agent:(Other "other") ~pane:"%2" Idle) ],
        [] );
    ];
  [%expect
    {|
    [claude --resume sess-1]
    [claude --continue]
    [pi --session pi-sess-1]
    [pi]
    []
    []
    |}]

(* A pane in a window with a run pane is a subagent's, never a prompt target; with the run mark
   gone, the same pane is one. *)
let%expect_test "prompt never targets a subagent's window" =
  let self = pane ~session:"alpha" ~window:"@0" "%1" in
  let panes run =
    [
      self;
      pane ~session:"alpha" ~window:"@1" ~index:1 ~cmd:"claude" "%2";
      pane ~session:"alpha" ~window:"@2" ~index:2 ~cmd:"claude" ?run "%3";
    ]
  in
  List.iter
    (fun run ->
      Prompt.agent_panes_in (panes run) State.Panes.empty ~pi:Procs.Int_set.empty self
        ~whole_session:true
      |> List.map (fun (p : Tmux.Pane.t) -> p.pane_id)
      |> String.concat " " |> print_endline)
    [ Some "run-abc"; None ];
  [%expect {|
    %2
    %2 %3
    |}]

let%expect_test "prompt refuses an empty prompt before asking tmux" =
  List.iter
    (fun text ->
      Printf.printf "%d\n" (Prompt.prompt ~dir:"/nonexistent" ~self:"%1" ~window:false text))
    [ ""; "\n" ];
  [%expect {|
    no prompt given
    no prompt given
    1
    1
    |}]

let%expect_test "window-focused validates the id before asking tmux" =
  let panes = lazy (failwith "tmux asked") in
  List.iter (fun w -> attempt (fun () -> Control.window_focused ~panes w)) [ ""; "@"; "7"; "@1x" ];
  attempt (fun () ->
      Control.window_focused
        ~panes:(Lazy.from_val [ pane ~window:"@4" ~active:true ~attached:true "%1" ])
        "@4");
  [%expect
    {|
    usage: kido window-focused WINDOW_ID
    window-focused: "@" is not a window id (@N)
    window-focused: "7" is not a window id (@N)
    window-focused: "@1x" is not a window id (@N)
    true
    |}]
