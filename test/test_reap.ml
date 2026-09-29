open Kido

let now = 1_700_000_000.
let temp () = Filename.temp_dir "kido-reap" ""
let runs dir = Filename.concat dir "runs"

let dead_pid () =
  let pid = Unix.create_process "true" [| "true" |] Unix.stdin Unix.stdout Unix.stderr in
  ignore (Unix.waitpid [] pid);
  pid

let pane ?run ?dead ?(watched = false) pane_id window_id : Tmux.Pane.t =
  {
    session_name = "s";
    session_id = "$0";
    session_created = 0.;
    window_index = 0;
    window_id;
    window_name = "";
    window_layout = "";
    pane_id;
    active = watched;
    pane_pid = 0;
    current_command = "";
    current_path = "";
    alternate_on = false;
    command_running = false;
    command_start = None;
    last_prompt = None;
    last_exit = None;
    command_line = "";
    dead_at = Option.map (fun secs -> now -. Float.of_int secs) dead;
    run;
    session_attached = watched;
    title = "";
  }

let other = pane "%other" "@other"

let session ?parent ?(pid = Unix.getpid ()) pane : State.session =
  {
    agent = Pi;
    pane;
    pid;
    status = Running;
    ts = now;
    title = "";
    inbox = "";
    ended = None;
    background = false;
    tool_pending = false;
    activity = "";
    parent = Option.map (fun session -> { State.session; pid = 0 }) parent;
    depth = 0;
    model = "";
  }

let no_capture _ = None
let id s = Result.get_exn (Subrun.parse_id s)

let sweep ?(dir = temp ()) ?(capture = no_capture) ?(sessions = []) panes =
  List.iter
    (fun (p : Tmux.Pane.t) ->
      Option.iter
        (fun r ->
          if not (Sys.file_exists (Filename.concat (runs dir) r)) then
            Subrun.create ~dir:(runs dir) (id r) "x")
        p.run)
    panes;
  Reap.sweep ~dir ~capture ~grace:30. panes sessions ~now

let show (closes, endings) =
  List.iter
    (fun (c : Reap.close) ->
      Printf.printf "close %s%s\n" c.window_id
        (Option.map_or ~default:"" (fun p -> " pane " ^ p) c.pane_id))
    closes;
  List.iter
    (fun (e : Reap.ending) ->
      Printf.printf "ending %S parent %S %s %S\n" e.meta.name e.meta.parent_session
        (Reap.string_of_result e.outcome.result)
        e.outcome.text)
    endings;
  if List.is_empty closes && List.is_empty endings then print_endline "nothing"

let run ~dir ?(kind : Subrun.kind option) ?(parent = "") name id_s =
  let i = id id_s in
  Subrun.create ~dir:(runs dir) i "task";
  Subrun.write_meta ~dir:(runs dir)
    {
      id = i;
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
      started_at = now;
    };
  i

let outcome ~dir id_s =
  match Subrun.read_outcome ~dir:(runs dir) (id id_s) with
  | None -> "no outcome"
  | Some o -> Reap.string_of_result o.result ^ " " ^ o.text

let%expect_test "rule 1: a finished run pane closes its window after the grace, with no record" =
  show (sweep [ other; pane ~run:"run-finished" ~dead:60 "%1" "@1" ]);
  show (sweep [ other; pane ~run:"run-grace" ~dead:1 "%1" "@1" ]);
  [%expect {|
    close @1
    nothing
    |}]

let%expect_test "an unmarked window is never touched, a stale record naming its pane or not" =
  let stale = ("child-sess", session ~parent:"long-gone-sess" "%1") in
  show (sweep ~sessions:[ stale ] [ other; pane ~dead:600 "%1" "@1" ]);
  [%expect {| nothing |}]

let%expect_test "a session's last window is never closed" =
  show (sweep [ pane ~run:"run-lastwindow" ~dead:600 "%1" "@1" ]);
  [%expect {| nothing |}]

let%expect_test "a focused window is collected once the user leaves" =
  show (sweep [ other; pane ~watched:true ~run:"run-read" ~dead:600 "%1" "@1" ]);
  show (sweep [ pane ~watched:true "%other" "@other"; pane ~run:"run-read" ~dead:600 "%1" "@1" ]);
  [%expect {|
    nothing
    close @1
    |}]

let%expect_test "rule 2: a live subagent of a dead parent is cancelled; of a live one, left alone" =
  let child = ("child-sess", session ~parent:"root-sess" "%1") in
  let panes = [ other; pane ~run:"run-cancelled" "%1" "@1" ] in
  show (sweep ~sessions:[ child; ("root-sess", session ~pid:(dead_pid ()) "%p") ] panes);
  show (sweep ~sessions:[ child; ("root-sess", session "%p") ] panes);
  [%expect {|
    close @1
    nothing
    |}]

let%expect_test "a root agent's record is nobody's to close, and both rules name a window once" =
  show
    (sweep
       ~sessions:[ ("root-sess", session ~pid:(dead_pid ()) "%1") ]
       [ other; pane ~run:"run-root" "%1" "@1" ]);
  show
    (sweep
       ~sessions:[ ("child-sess", session ~parent:"gone-sess" "%1") ]
       [ other; pane ~run:"run-once" ~dead:600 "%1" "@1" ]);
  [%expect {|
    nothing
    close @1
    |}]

let%expect_test "a pane collision on the parent: the complete record set keeps the child" =
  let dir = temp () in
  ignore (run ~dir ~kind:Bash ~parent:"parent-sess" "build" "run-collision");
  let record id s = Result.get_exn (State.record ~dir id s) in
  record "parent-sess" (session "%p");
  record "child-sess" (session ~parent:"parent-sess" "%1");
  record "intruder-sess" { (session "%p") with ts = now +. 1. };
  let panes = [ other; pane ~run:"run-collision" "%1" "@1" ] in
  show (sweep ~dir ~sessions:(State.load_live ~dir) panes);
  print_endline (outcome ~dir "run-collision");
  let lossy = State.Panes.bindings (State.by_pane (State.load_live ~dir)) |> List.map snd in
  Printf.printf "intruder won the pane: %b\n"
    (List.exists (fun (id, _) -> String.equal id "intruder-sess") lossy);
  show (sweep ~dir ~sessions:lossy panes);
  [%expect
    {|
    nothing
    no outcome
    intruder won the pane: true
    close @1
    ending "build" parent "parent-sess" failed "ended without its wrapper reporting"
    |}]

let%expect_test "outcomes: Died is recorded for a closed window and a recorded one stands" =
  let dir = temp () in
  Subrun.create ~dir:(runs dir) (id "run-died") "x";
  show (sweep ~dir [ other; pane ~run:"run-died" ~dead:60 "%1" "@1" ]);
  print_endline (outcome ~dir "run-died");
  Subrun.create ~dir:(runs dir) (id "run-done") "x";
  ignore
    (Subrun.record_outcome ~dir:(runs dir) (id "run-done")
       { result = Completed; text = ""; at = Some now });
  show (sweep ~dir [ other; pane ~run:"run-done" ~dead:60 "%1" "@1" ]);
  print_endline (outcome ~dir "run-done");
  [%expect {|
    close @1
    died
    close @1
    completed
    |}]

let stub pane_id text p = if String.equal p pane_id then Some text else None

let screen ~dir id_s =
  match Subrun.read_screen ~dir:(runs dir) (id id_s) with
  | None -> "no screen"
  | Some s ->
      Printf.sprintf "%d bytes, ends %S" (String.length s)
        (String.take 12 (String.rev s) |> String.rev)

let%expect_test "the screen is captured before closing, only for a window actually closed" =
  let dir = temp () in
  Subrun.create ~dir:(runs dir) (id "run-crash") "x";
  show
    (sweep ~dir
       ~capture:(stub "%1" "panic: something went wrong\n")
       [ other; pane ~run:"run-crash" ~dead:60 "%1" "@1" ]);
  print_endline (screen ~dir "run-crash");
  Subrun.create ~dir:(runs dir) (id "run-focused") "x";
  show
    (sweep ~dir ~capture:(stub "%1" "never")
       [ other; pane ~watched:true ~run:"run-focused" ~dead:600 "%1" "@1" ]);
  print_endline (screen ~dir "run-focused");
  Subrun.create ~dir:(runs dir) (id "run-lastwindow") "x";
  show (sweep ~dir ~capture:(stub "%2" "never") [ pane ~run:"run-lastwindow" ~dead:600 "%2" "@2" ]);
  print_endline (screen ~dir "run-lastwindow");
  Subrun.create ~dir:(runs dir) (id "run-nopane") "x";
  show
    (sweep ~dir ~capture:(stub "%never" "x") [ other; pane ~run:"run-nopane" ~dead:60 "%1" "@1" ]);
  print_endline (screen ~dir "run-nopane");
  [%expect
    {|
    close @1
    28 bytes, ends " went wrong\n"
    nothing
    no screen
    nothing
    no screen
    close @1
    no screen
    |}]

let%expect_test "the captured screen is bounded to its tail" =
  let dir = temp () in
  Subrun.create ~dir:(runs dir) (id "run-huge") "x";
  let huge = String.make (Subrun.max_screen_bytes * 2) 'x' ^ "TAIL" in
  show (sweep ~dir ~capture:(stub "%1" huge) [ other; pane ~run:"run-huge" ~dead:60 "%1" "@1" ]);
  Printf.printf "%s, within bound: %b\n" (screen ~dir "run-huge")
    (String.length (Option.get_exn_or "screen" (Subrun.read_screen ~dir:(runs dir) (id "run-huge")))
    <= Subrun.max_screen_bytes);
  [%expect {|
    close @1
    65536 bytes, ends "xxxxxxxxTAIL", within bound: true
    |}]

let%expect_test
    "a bash run nobody reported notifies once between two observers; a reported one not at all" =
  let dir = temp () in
  ignore (run ~dir ~kind:Bash ~parent:"root-sess" "build" "run-killed");
  let panes = [ other; pane ~run:"run-killed" ~dead:60 "%1" "@1" ] in
  show (sweep ~dir panes);
  show (sweep ~dir panes);
  print_endline (outcome ~dir "run-killed");
  ignore (run ~dir ~kind:Bash ~parent:"root-sess" "build" "run-told");
  ignore
    (Subrun.record_outcome ~dir:(runs dir) (id "run-told")
       { result = Failed; text = "exit status 3"; at = Some now });
  show (sweep ~dir [ other; pane ~run:"run-told" ~dead:60 "%1" "@1" ]);
  print_endline (outcome ~dir "run-told");
  [%expect
    {|
    close @1
    ending "build" parent "root-sess" failed "ended without its wrapper reporting"
    close @1
    failed ended without its wrapper reporting
    close @1
    failed exit status 3
    |}]

let%expect_test
    "an agent run nobody reported notifies Died; one that reported is left to its own story" =
  let dir = temp () in
  ignore (run ~dir ~parent:"root-sess" "kid" "run-agent");
  show (sweep ~dir [ other; pane ~run:"run-agent" ~dead:60 "%1" "@1" ]);
  print_endline (outcome ~dir "run-agent");
  ignore (run ~dir ~parent:"root-sess" "kid" "run-said");
  ignore
    (Subrun.record_outcome ~dir:(runs dir) (id "run-said")
       { result = Completed; text = ""; at = Some now });
  show (sweep ~dir [ other; pane ~run:"run-said" ~dead:60 "%1" "@1" ]);
  print_endline (outcome ~dir "run-said");
  [%expect
    {|
    close @1
    ending "kid" parent "root-sess" died ""
    died
    close @1
    completed
    |}]

let%expect_test "a parentless bash run tells nobody but is still recorded" =
  let dir = temp () in
  ignore (run ~dir ~kind:Bash "build" "run-loner");
  show (sweep ~dir [ other; pane ~run:"run-loner" ~dead:60 "%1" "@1" ]);
  print_endline (outcome ~dir "run-loner");
  [%expect {|
    close @1
    failed ended without its wrapper reporting
    |}]

let%expect_test "a run's pane in a shared window: the pane goes, the split stays" =
  let run = pane ~run:"run-split" ~dead:600 "%1" "@1" and shell = pane "%2" "@1" in
  show (sweep [ other; run; shell ]);
  show (sweep [ other; run ]);
  show (sweep [ other; pane ~run:"run-young" ~dead:1 "%1" "@1"; shell ]);
  show (sweep [ other; pane ~run:"run-going" "%1" "@1"; pane ~dead:600 "%2" "@1" ]);
  show (sweep [ other; run; pane ~watched:true "%2" "@1" ]);
  show (sweep [ pane ~watched:true "%other" "@other"; run; { shell with session_attached = true } ]);
  show (sweep [ run; shell ]);
  [%expect
    {|
    close @1 pane %1
    close @1
    nothing
    nothing
    nothing
    close @1 pane %1
    close @1 pane %1
    |}]

let%expect_test "a pane close captures the run's pane alone and notifies once" =
  let dir = temp () in
  Subrun.create ~dir:(runs dir) (id "run-screen") "x";
  let shell = pane "%2" "@1" in
  show
    (sweep ~dir
       ~capture:(stub "%1" "the run's last screen\n")
       [ other; pane ~run:"run-screen" ~dead:600 "%1" "@1"; shell ]);
  print_endline (Option.get_exn_or "screen" (Subrun.read_screen ~dir:(runs dir) (id "run-screen")));
  ignore (run ~dir ~kind:Bash ~parent:"root-sess" "build" "run-paned");
  let panes = [ other; pane ~run:"run-paned" ~dead:600 "%1" "@1"; shell ] in
  show (sweep ~dir panes);
  show (sweep ~dir panes);
  print_endline (outcome ~dir "run-paned");
  [%expect
    {|
    close @1 pane %1
    the run's last screen

    close @1 pane %1
    ending "build" parent "root-sess" failed "ended without its wrapper reporting"
    close @1 pane %1
    failed ended without its wrapper reporting
    |}]

let%expect_test
    "an orphan with a split is cancelled by its own pane; a restarted parent keeps its child" =
  let child = ("child-sess", session ~parent:"root-sess" "%1") in
  show
    (sweep
       ~sessions:[ child; ("root-sess", session ~pid:(dead_pid ()) "%p") ]
       [ other; pane ~run:"run-orphan" "%1" "@1"; pane "%2" "@1" ]);
  show
    (sweep
       ~sessions:
         [ ("child-sess", session ~parent:"parent-sess" "%1"); ("parent-sess", session "%p") ]
       [ other; pane ~run:"run-restarted" "%1" "@1" ]);
  [%expect {|
    close @1 pane %1
    nothing
    |}]

let%expect_test "decide: close-run's refusals and closes" =
  let show w panes =
    match Reap.decide panes w with
    | Ok c ->
        Printf.printf "close %s%s\n" c.window_id
          (Option.map_or ~default:"" (fun p -> " pane " ^ p) c.pane_id)
    | Error why -> print_endline why
  in
  let focused = pane ~watched:true "%1" "@1" in
  show "@2" [ focused; pane ~run:"run-x" ~dead:1 "%2" "@2"; pane "%3" "@2" ];
  show "@2" [ focused; pane ~run:"run-x" ~dead:1 "%2" "@2" ];
  show "@2" [ focused; pane ~run:"run-x" "%2" "@2"; pane ~dead:1 "%3" "@2" ];
  show "@2" [ pane "%1" "@1"; pane ~run:"run-x" ~dead:1 "%2" "@2"; pane ~watched:true "%3" "@2" ];
  show "@1" [ pane ~run:"run-x" ~dead:1 "%1" "@1"; pane "%2" "@1" ];
  show "@1" [ focused; pane "%2" "@2" ];
  show "@2" [ focused; pane ~dead:1 "%2" "@2" ];
  show "@1" [ pane ~run:"run-x" ~dead:1 "%1" "@1" ];
  [%expect
    {|
    close @2 pane %2
    close @2
    @2's run is still going; leaving it
    @2 is a client's current window; leaving it for the user to read
    close @1 pane %1
    @1 is a client's current window; leaving it for the user to read
    @2 has no run pane; leaving it
    @1 is its session's only window; closing it would destroy the session
    |}]

let%expect_test "a bash ending's notice carries the run's name, status, id and output tail" =
  let dir = temp () in
  let i = run ~dir ~kind:Bash "build" "run-named" in
  Fs.write (Subrun.output_path ~dir:(runs dir) i) "boom\n";
  let meta = Option.get_exn_or "meta" (Subrun.read_meta ~dir:(runs dir) i) in
  let body e = print_string (String.replace ~sub:dir ~by:"DIR" (Reap.body ~dir e)) in
  body
    {
      meta;
      outcome = { result = Failed; text = "exit status 3"; at = None };
      detail = Bash { unstreamed = 2 };
    };
  body
    {
      meta = { meta with name = "" };
      outcome = { result = Completed; text = "exit status 0"; at = None };
      detail = Bash { unstreamed = 0 };
    };
  Fs.remove (Subrun.output_path ~dir:(runs dir) i);
  print_string
    (Reap.body ~dir
       {
         meta;
         outcome = { result = Failed; text = "x"; at = None };
         detail = Bash { unstreamed = 0 };
       }
    |> String.split_on_char '\n' |> List.last_opt |> Option.get_exn_or "line"
    |> String.replace ~sub:dir ~by:"DIR");
  [%expect
    {|
    async run "build" failed: exit status 3
    run: run-named
    output: DIR/runs/run-named/output
    2 lines not streamed (the output file above has every one)
    --- output ---
    boom
    async run "run-named" completed: exit status 0
    run: run-named
    output: DIR/runs/run-named/output
    --- output ---
    boom
    --- output unreadable: DIR/runs/run-named/output: No such file or directory ---
    |}]

let%expect_test "an agent ending's notice, reported and unreported" =
  let dir = temp () in
  let i = run ~dir ~parent:"root-sess" "kid" "run-agent" in
  let meta = Option.get_exn_or "meta" (Subrun.read_meta ~dir:(runs dir) i) in
  print_string
    (Reap.body ~dir
       {
         meta;
         outcome = { result = Died; text = ""; at = None };
         detail = Agent { unreported = false };
       });
  print_string
    (Reap.body ~dir
       {
         meta;
         outcome = { result = Stopped; text = "killed by stop_subagent"; at = None };
         detail = Agent { unreported = true };
       });
  [%expect
    {|
    subagent "kid" ended without recording an outcome of its own, so kido recorded it as died; whether it called notify_parent is not known, and any report it sent stands
    run: run-agent
    resume: spawn_subagent(resume: "run-agent")
    subagent "kid" stopped without reporting: it never called notify_parent, so this is the whole account of it
    detail: killed by stop_subagent
    run: run-agent
    resume: spawn_subagent(resume: "run-agent")
    |}]

let%expect_test "tail_of_file keeps the end, drops a partial rune and stays valid UTF-8" =
  let dir = temp () in
  let path = Filename.concat dir "output" in
  Fs.write path (String.concat "" (List.init 1000 (Printf.sprintf "line %04d\n")));
  let tail, omitted = Reap.tail_of_file path Reap.max_notice_tail_bytes in
  Printf.printf "%d bytes, %d omitted, ends %S, has head: %b\n" (String.length tail) omitted
    (String.rev (String.take 10 (String.rev tail)))
    (String.mem ~sub:"line 0000\n" tail);
  Fs.write path "all of it\n";
  let tail, omitted = Reap.tail_of_file path Reap.max_notice_tail_bytes in
  Printf.printf "%S %d\n" tail omitted;
  let s = "ab🎉cd" in
  Fs.write path s;
  for cut = 3 to 5 do
    let tail, _ = Reap.tail_of_file path (String.length s - cut) in
    Printf.printf "cut %d: %S\n" cut tail
  done;
  Fs.write path (String.repeat "☃" 10);
  let tail, omitted = Reap.tail_of_file path 4 in
  Printf.printf "%S %d\n" tail omitted;
  [%expect
    {|
    4000 bytes, 6000 omitted, ends "line 0999\n", has head: false
    "all of it\n" 0
    cut 3: "cd"
    cut 4: "cd"
    cut 5: "cd"
    "\226\152\131" 27
    |}]
