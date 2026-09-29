open Kido
open Fixture

(* A model writes a command line, which has to reach a shell; separate words must not be joined. *)
let%expect_test "one word is a shell command line, several an argv" =
  List.iter
    (fun args -> Printf.printf "[%s]\n" (String.concat "|" (Async_bash.command_argv args)))
    [ []; [ "make -j8 && ./run" ]; [ "sh"; "-c"; "exit 3" ] ];
  [%expect {|
    []
    [bash|-c|make -j8 && ./run]
    [sh|-c|exit 3]
    |}]

(* Nothing a name is derived to may be a path, empty, or what tmux's parser cannot carry. *)
let%expect_test "a window name derived from the command" =
  List.iter
    (fun c ->
      let name = Async_bash.derived_name [ c ] in
      Printf.printf "%S -> %s%s\n" c name
        (match Launch.tmux_safe "name" name with Ok () -> "" | Error _ -> " UNSAFE"))
    [ "make -j8"; "/usr/bin/env python"; ""; "'"; "./x$y"; String.make 70 'a' ];
  [%expect
    {|
    "make -j8" -> make
    "/usr/bin/env python" -> env
    "" -> bash
    "'" -> bash
    "./x$y" -> xy
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" -> aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    |}]

let%expect_test "a run's meta and command are written, then a window running kido async-run" =
  let dir = Filename.temp_dir "kido-state" "" in
  ignore (State.record ~dir "caller-sess" (session ~pane:"%1" ~depth:1 Idle));
  let calls = ref [] in
  let tmux : Spawn_subagent.tmux =
    {
      new_window =
        (fun ~session ~name ~cwd ~env command ->
          calls := (session, name, cwd, env, command) :: !calls;
          { window_id = "@9"; pane_id = "%9"; pane_pid = 4242 });
      mark_run = (fun _ _ -> ());
      window_exists = (fun _ -> true);
      kill_window = (fun _ -> ());
    }
  in
  let panes = lazy [ pane ~session_id:"$1" ~cwd:"/work" "%1"; pane ~session_id:"$1" "%2" ] in
  let start ~self ~name ~stream args =
    let line = Async_bash.async_bash ~dir ~self ~exe:"/bin/kido" ~panes ~tmux ~name ~stream args in
    let runs = Filename.concat dir "runs" in
    let id = List.hd (String.split_on_char ' ' line |> List.drop 2) in
    let scrub s =
      String.replace ~sub:id ~by:"<run>" s
      |> String.replace ~sub:dir ~by:"<dir>"
      |> String.replace ~sub:(Printf.sprintf "=%d " (Unix.getpid ())) ~by:"=<pid> "
    in
    print_endline (scrub line);
    let id = Result.get_exn (Subrun.parse_id id) in
    let m = Option.get_exn_or "meta" (Subrun.read_meta ~dir:runs id) in
    Printf.printf "meta %s parent=%S depth=%d pane=%s pid=%d\n" m.name m.parent_session m.depth
      m.pane m.pid;
    Printf.printf "command [%s] task %S\n"
      (String.concat "|" (Option.get_or ~default:[] (Subrun.read_command ~dir:runs id)))
      (Option.get_or ~default:"" (Subrun.read_task ~dir:runs id));
    List.iter
      (fun (session, name, cwd, env, command) ->
        Printf.printf "new-window %s %S %s\n  env %s\n  cmd %s\n" session name cwd
          (scrub (String.concat " " env))
          (scrub (String.concat " " command)))
      !calls;
    calls := []
  in
  start ~self:"%1" ~name:"" ~stream:false [ "make -j8 && ./run" ];
  (* No caller record: no edge, depth 1. *)
  start ~self:"%2" ~name:"build" ~stream:true [ "sh"; "-c"; "exit 3" ];
  (match
     Async_bash.async_bash ~dir ~self:"%1" ~exe:"/bin/kido" ~panes ~tmux ~name:"" ~stream:false []
   with
  | _ -> ()
  | exception Failure m -> print_endline m);
  [%expect
    {|
    @9 %9 <run> <dir>/runs/<run>/output
    meta make parent="caller-sess" depth=2 pane=%9 pid=4242
    command [bash|-c|make -j8 && ./run] task "make -j8 && ./run"
    new-window $1 "make" /work
      env KIDO_AGENT_TASK_FILE=<dir>/runs/<run>/task KIDO_AGENT_RUN_ID=<run> KIDO_AGENT_DEPTH=2 KIDO_AGENT_PARENT_PID=<pid> KIDO_AGENT_PARENT_SESSION=caller-sess KIDO_STATE_DIR=<dir>
      cmd /bin/kido async-run --run-id <run>
    @9 %9 <run> <dir>/runs/<run>/output
    meta build parent="" depth=1 pane=%9 pid=4242
    command [sh|-c|exit 3] task "sh -c exit 3"
    new-window $1 "build"
      env KIDO_AGENT_TASK_FILE=<dir>/runs/<run>/task KIDO_AGENT_RUN_ID=<run> KIDO_AGENT_DEPTH=1 KIDO_STATE_DIR=<dir>
      cmd /bin/kido async-run --run-id <run> --stream
    no command given
    usage: kido async_bash [--name NAME] [--stream] -- COMMAND [ARG...]
    |}]
