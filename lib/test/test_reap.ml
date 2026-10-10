open Kido

let now = 1_700_000_000.
let temp () = Filename.temp_dir "kido-reap" ""

let pane ?run ?dead ?(watched = false) pane_id window_id : Tmux.Pane.t =
  {
    session_name = "s";
    session_id = Option.get_exn_or "id" (Tmux.Session.of_string "$0");
    session_created = 0.;
    window_index = 0;
    window_id = Option.get_exn_or "id" (Tmux.Window.of_string window_id);
    window_name = "";
    window_layout = "";
    pane_id = Option.get_exn_or "id" (Tmux.Pane.of_string pane_id);
    active = watched;
    pane_active = watched;
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
    ssh = None;
    session_attached = watched;
    program_status = { serial = 0; records = [] };
    title = "";
  }

let id s = Result.get_exn (Subrun.parse_id s)

let run ~dir ?(kind = Subrun.Agent) ?(parent = "") name id_s =
  let i = id id_s in
  Subrun.create ~dir i "task";
  Subrun.write_meta ~dir
    {
      id = i;
      name;
      kind;
      parent_session = parent;
      depth = 0;
      pane = Tmux.Pane.of_string "";
      pid = 0;
      cwd = "";
      model = "";
      tools = [];
      keep_alive = false;
      started_at = now;
    };
  i

let%expect_test "decide: close-run's refusals and closes" =
  let show w panes =
    match Reap.decide panes (Option.get_exn_or "id" (Tmux.Window.of_string w)) with
    | Ok (Window w) -> Printf.printf "close %s\n" (Tmux.Window.to_string w)
    | Ok (Pane { window; pane }) ->
        Printf.printf "close %s pane %s\n" (Tmux.Window.to_string window) (Tmux.Pane.to_string pane)
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
  show "@2" [ focused; pane ~run:"run-x" ~dead:1 "%2" "@2"; pane ~run:"run-y" ~dead:1 "%3" "@2" ];
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
    close @2 pane %2
    |}]

let%expect_test "a bash ending's notice carries the run's name, status, id and output tail" =
  let dir = temp () in
  let i = run ~dir ~kind:Bash "build" "run-named" in
  Fs.write (Subrun.output_path ~dir i) "boom\n";
  let meta = Option.get_exn_or "meta" (Subrun.read_meta ~dir i) in
  let body e = print_string (String.replace ~sub:dir ~by:"DIR" (Reap.body ~dir e)) in
  body { meta; outcome = { result = Failed; text = "exit status 3"; at = None }; detail = Bash };
  body
    {
      meta = { meta with name = "" };
      outcome = { result = Completed; text = "exit status 0"; at = None };
      detail = Bash;
    };
  body
    {
      meta;
      outcome = { result = Completed; text = "exit status 0"; at = None };
      detail = Streamed { unstreamed = 2 };
    };
  body
    {
      meta;
      outcome = { result = Completed; text = "exit status 0"; at = None };
      detail = Streamed { unstreamed = 0 };
    };
  Fs.remove (Subrun.output_path ~dir i);
  print_string
    (Reap.body ~dir { meta; outcome = { result = Failed; text = "x"; at = None }; detail = Bash }
    |> String.split_on_char '\n' |> List.last_opt |> Option.get_exn_or "line"
    |> String.replace ~sub:dir ~by:"DIR");
  [%expect
    {|
    async run "build" failed: exit status 3
    run: run-named
    output: DIR/runs/run-named/output
    --- output ---
    boom
    async run "run-named" completed: exit status 0
    run: run-named
    output: DIR/runs/run-named/output
    --- output ---
    boom
    async run "build" completed: exit status 0
    run: run-named
    output: DIR/runs/run-named/output
    2 lines not streamed (the output file above has every one)
    async run "build" completed: exit status 0
    run: run-named
    output: DIR/runs/run-named/output
    --- output unreadable: DIR/runs/run-named/output: No such file or directory ---
    |}]

let%expect_test "an agent ending's notice, reported and unreported" =
  let dir = temp () in
  let i = run ~dir ~parent:"root-sess" "kid" "run-agent" in
  let meta = Option.get_exn_or "meta" (Subrun.read_meta ~dir i) in
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
         outcome = { result = Stopped; text = "killed by stop_run"; at = None };
         detail = Agent { unreported = true };
       });
  [%expect
    {|
    subagent "kid" ended without recording an outcome of its own, so kido recorded it as died; whether it called notify_parent is not known, and any report it sent stands
    run: run-agent
    resume: spawn_subagent(resume: "run-agent")
    subagent "kid" stopped without reporting: it never called notify_parent, so this is the whole account of it
    detail: killed by stop_run
    run: run-agent
    resume: spawn_subagent(resume: "run-agent")
    |}]

(* The tail is cut at Msg.max_notice_bytes; a character the cut splits is dropped whole. *)
let%expect_test "a bash notice keeps the output's tail, whole characters only" =
  let dir = temp () in
  let i = run ~dir ~kind:Bash "build" "run-tail" in
  let meta = Option.get_exn_or "meta" (Subrun.read_meta ~dir i) in
  let tail output =
    Fs.write (Subrun.output_path ~dir i) output;
    match
      Reap.body ~dir
        { meta; outcome = { result = Completed; text = "exit status 0"; at = None }; detail = Bash }
      |> String.lines |> List.drop 3
    with
    | header :: first :: rest ->
        Printf.printf "%s %S..%S\n" header (String.take 12 first)
          (List.last_opt rest |> Option.get_or ~default:first |> String.rev |> String.take 12
         |> String.rev)
    | lines -> List.iter print_endline lines
  in
  tail (String.concat "" (List.init 1000 (Printf.sprintf "line %04d\n")));
  tail "all of it\n";
  List.iter
    (fun keep -> tail ("ab\xf0\x9f\x8e\x89cd" ^ String.make (Msg.max_notice_bytes - keep) 'x'))
    [ 3; 4; 5; 6 ];
  tail (String.repeat "\xe2\x98\x83" ((Msg.max_notice_bytes / 3) + 1));
  [%expect
    {|
    --- last 4000 bytes of output (6000 omitted) --- "line 0600".."line 0999"
    --- output --- "all of it".."all of it"
    --- last 3999 bytes of output (6 omitted) --- "cdxxxxxxxxxx".."xxxxxxxxxxxx"
    --- last 3998 bytes of output (6 omitted) --- "cdxxxxxxxxxx".."xxxxxxxxxxxx"
    --- last 3997 bytes of output (6 omitted) --- "cdxxxxxxxxxx".."xxxxxxxxxxxx"
    --- last 4000 bytes of output (2 omitted) --- "\240\159\142\137cdxxxxxx".."xxxxxxxxxxxx"
    --- last 3999 bytes of output (3 omitted) --- "\226\152\131\226\152\131\226\152\131\226\152\131".."\226\152\131\226\152\131\226\152\131\226\152\131"
    |}]
