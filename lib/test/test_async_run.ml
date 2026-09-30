open Kido
open Fixture

let knobs : Async_stream.knobs = { batch = 0.02; backoff_floor = 0.02; backoff_cap = 0.1 }
let warn = Printf.printf "\nwarning: %s"

let async_run ?(stream = false) ~dir run_id =
  match Async_run.async_run ~dir ~knobs ~warn ~run_id ~stream [] with
  | Ok code -> Printf.printf "\n-> %d\n" code
  | Error m -> Printf.printf "\nrefused: %s\n" m

let outcome ~dir (meta : Subrun.meta) =
  match Subrun.read_outcome ~dir meta.id with
  | None -> print_endline "no outcome"
  | Some o -> Printf.printf "outcome %s %S\n" (Subrun.string_of_result o.result) o.text

let bash ?parent ~dir name command = run ~dir ~name ~kind:Bash ?parent ~command name

(* Everything a parent needs is on disk by the time the wrapper returns, so a window that loses the
   remain-on-exit race costs only the corpse on screen: the command exits at once for that reason.
   Its exit code is the wrapper's, for #{pane_dead_status}. *)
let%expect_test "the wrapper tees both streams, and records the ending before it returns" =
  let dir = Filename.temp_dir "kido-state" "" in
  List.iter
    (fun (name, command) ->
      let meta = bash ~dir name command in
      async_run ~dir name;
      outcome ~dir meta;
      Printf.printf "output file: %S\n"
        (Option.get_or ~default:"none" (Fs.read (Subrun.output_path ~dir meta.id))))
    [
      ("build", [ "sh"; "-c"; "printf out; printf err >&2; exit 3" ]);
      ("ok", [ "true" ]);
      ("killed", [ "sh"; "-c"; "kill -KILL $$" ]);
      ("missing", [ "no-such-command-kido" ]);
    ];
  [%expect
    {|
    outerr
    -> 3
    outcome failed "exit status 3"
    output file: "outerr"

    -> 0
    outcome completed "exit status 0"
    output file: ""

    -> 1
    outcome failed "signal: killed"
    output file: ""

    refused: exec: "no-such-command-kido": No such file or directory
    outcome failed "exec: \"no-such-command-kido\": No such file or directory"
    output file: ""
    |}]

let%expect_test "the run comes from its record, never the command line" =
  let dir = Filename.temp_dir "kido-state" "" in
  (match Async_run.async_run ~dir ~knobs ~warn ~run_id:"x" ~stream:false [ "make" ] with
  | Ok _ -> ()
  | Error m -> print_endline m);
  async_run ~dir "";
  async_run ~dir "no-such-run";
  [%expect
    {|
    unknown argument "make"; the command comes from the run's own record, not the command line
    usage: kido async-run [--run-id ID] [--stream]

    refused: --run-id is required (or $KIDO_AGENT_RUN_ID)
    usage: kido async-run [--run-id ID] [--stream]

    refused: run no-such-run has no meta
    |}]

(* The outcome write decides who saw the ending first: a wrapper finding one there keeps that story
   and sends nothing. The silence means something only beside the same wrapper, having won, trying
   to notify a parent that is gone and saying so. *)
let%expect_test "a wrapper that loses the outcome race says nothing" =
  let dir = Filename.temp_dir "kido-state" "" in
  let parent = "nobody-alive-reports-this" in
  let lost = bash ~dir ~parent "raced" [ "true" ] in
  ignore (Subrun.record_outcome ~dir lost.id { result = Stopped; text = ""; at = None });
  async_run ~dir "raced";
  outcome ~dir lost;
  let _ = bash ~dir ~parent "won" [ "true" ] in
  async_run ~dir "won";
  [%expect
    {|
    -> 0
    outcome stopped ""

    warning: no live process holds session "nobody-alive-reports-this"; the parent is gone, nothing sent
    -> 0
    |}]

(* The stream closes before the notice goes, so the notice follows the final chunk. *)
let%expect_test "--stream sends the output as it runs, then the ending" =
  let dir = Filename.temp_dir "kido-state" "" in
  let inbox, received = start_inbox ~reply:"ok\n" in
  Result.get_exn (State.record ~dir "root-sess" (session ~pane:"%2" ~inbox Idle));
  let _ = bash ~dir ~parent:"root-sess" "chatty" [ "printf"; "one\\ntwo\\nthree" ] in
  async_run ~stream:true ~dir "chatty";
  (* However the lines were batched, every one is streamed before the notice. *)
  List.filter_map Msg.parse (received ())
  |> List.fold_left
       (fun (streamed, lines) (e : Msg.envelope) ->
         match e.kind with
         | Stream -> (streamed @ String.lines e.text, lines)
         | _ ->
             ( streamed,
               lines
               @ [
                   Printf.sprintf "%s after [%s]: %s" (Msg.string_of_kind e.kind)
                     (String.concat " " streamed)
                     (List.hd (String.lines e.text));
                 ] ))
       ([], [])
  |> snd |> List.iter print_endline;
  [%expect
    {|
    one
    two
    three
    -> 0
    notice after [one two three]: async run "chatty" completed: exit status 0
    |}]

(* Being killed is exactly the ending nobody else is watching for. Run as its own process, since
   the signal is the wrapper's to catch. *)
let%expect_test "a signalled wrapper passes the signal on, records the ending and exits 1" =
  let dir = Filename.temp_dir "kido-state" "" in
  let meta = bash ~dir "doomed" [ "sleep"; "30" ] in
  let wrapper =
    Unix.create_process_env "../../bin/main.exe"
      [| "kido"; "async-run"; "--run-id"; "doomed" |]
      [| "KIDO_STATE_DIR=" ^ dir; "PATH=" ^ Sys.getenv "PATH" |]
      Unix.stdin Unix.stdout Unix.stderr
  in
  let output = Subrun.output_path ~dir meta.id in
  let deadline = Unix.gettimeofday () +. 5. in
  while (not (Sys.file_exists output)) && Float.(Unix.gettimeofday () < deadline) do
    Unix.sleepf 0.02
  done;
  Unix.kill wrapper Sys.sigterm;
  (match Unix.waitpid [] wrapper with
  | _, WEXITED code -> Printf.printf "exit %d\n" code
  | _ -> print_endline "not an exit");
  outcome ~dir meta;
  [%expect {|
    exit 1
    outcome failed "killed by terminated"
    |}]
