type info = { meta : Subrun.meta; outcome : Subrun.outcome option }

let yojson_of_info { meta; outcome } =
  Yojson.Safe.Util.combine (Subrun.yojson_of_meta meta)
    (`Assoc
       (Option.map_or ~default:[] (fun o -> [ ("outcome", Subrun.yojson_of_outcome o) ]) outcome))

let load ?parent_session ~dir id =
  Option.flat_map
    (fun (meta : Subrun.meta) ->
      if Option.exists (fun parent -> not (String.equal parent meta.parent_session)) parent_session
      then None
      else Some { meta; outcome = Subrun.effective_outcome ~dir id ~pid:meta.pid })
    (Subrun.read_meta ~dir id)

let seconds t = Timestamp.to_local_string (Float.of_int (Float.to_int t))

let list ?parent_session ~dir () =
  List.filter_map (load ?parent_session ~dir) (Subrun.list ~dir)
  |> List.sort (fun a b -> Float.compare b.meta.started_at a.meta.started_at)

let table ~now infos =
  [ "ID"; "NAME"; "PARENT"; "STARTED"; "DURATION"; "OUTCOME"; "CWD" ]
  :: List.map
       (fun { meta = m; outcome } ->
         let outcome, duration =
           match outcome with
           | None -> ("running", Some now)
           | Some o -> (Subrun.string_of_result o.result, o.at)
         in
         [
           Subrun.string_of_id m.id;
           m.name;
           m.parent_session;
           seconds m.started_at;
           Option.map_or ~default:"-"
             (fun t -> Timestamp.duration (Float.round (t -. m.started_at)))
             duration;
           outcome;
           m.cwd;
         ])
       infos

let show ~dir ~json id_str =
  let open Result.Infix in
  let* id = Subrun.parse_id id_str in
  let+ info = Option.to_result (Printf.sprintf "run %S: no such run" id_str) (load ~dir id) in
  let m = info.meta in
  let task = Option.get_or ~default:"" (Subrun.read_task ~dir id) in
  let screen = Subrun.read_screen ~dir id in
  let cd = "cd " ^ Filename.quote m.cwd ^ " && " in
  let resume = cd ^ "kido tool spawn_subagent --resume " ^ id_str in
  let fork = cd ^ "pi --fork " ^ id_str in
  if json then
    Yojson.Safe.to_string
      (Yojson.Safe.Util.combine (yojson_of_info info)
         (`Assoc
            ([ ("task", `String task); ("resume", `String resume); ("fork", `String fork) ]
            @ Option.map_or ~default:[] (fun s -> [ ("screen", `String s) ]) screen)))
    ^ "\n"
  else begin
    let b = Buffer.create 1024 in
    let line k v = Printf.bprintf b "%-10s%s\n" (k ^ ":") v in
    line "id" id_str;
    line "name" m.name;
    line "kind" (Subrun.string_of_kind m.kind);
    line "parent" m.parent_session;
    line "depth" (string_of_int m.depth);
    line "cwd" m.cwd;
    if not (String.is_empty m.model) then line "model" m.model;
    if not (List.is_empty m.tools) then line "tools" ("[" ^ String.concat " " m.tools ^ "]");
    if m.keep_alive then Buffer.add_string b "keepAlive: true\n";
    line "started" (seconds m.started_at);
    (match info.outcome with
    | None -> line "outcome" "running"
    | Some o ->
        line "outcome" (Subrun.string_of_result o.result);
        Option.iter (fun at -> line "ended" (seconds at)) o.at;
        if not (String.is_empty o.text) then line "detail" o.text);
    if Subrun.has_report ~dir id then line "report" (Subrun.report_path ~dir id);
    line "resume" resume;
    line "fork" fork;
    Printf.bprintf b "task:\n%s\n" task;
    Option.iter (Printf.bprintf b "screen:\n%s\n") screen;
    Buffer.contents b
  end

(* pi prints this and exits 0 when it cannot resolve a provider for the model it was given: the one
   line that names why no turn ever ran. Matched by substring, since it is pi's wording. *)
let login_line = "Use /login to log into a provider via OAuth or API key"

let refine_no_turn_detail text screen =
  if String.mem ~sub:"no turn ever ran" text && String.mem ~sub:login_line screen then
    Printf.sprintf "%s (the pane showed: \"%s\")" text login_line
  else text

let run_outcome ~dir ~warn ~result ~text ~unreported id_str =
  let open Result.Infix in
  let* id = Subrun.parse_id id_str in
  let meta = Subrun.read_meta ~dir id in
  let text =
    match (meta, result) with
    | Some m, Subrun.Failed ->
        Option.map_or ~default:text (refine_no_turn_detail text)
          (Subrun.save_screen (Tmux.create ()) ~dir id m.pane)
    | _ -> text
  in
  let outcome : Subrun.outcome = { result; text; at = Some (Timestamp.now ()) } in
  match meta with
  | Some meta when unreported ->
      Option.iter
        (fun (e : Reap.ending) ->
          Result.iter_err
            (fun err -> warn (Msg.string_of_error err))
            (Reap.send ~dir { e with detail = Agent { unreported = true } }))
        (Reap.record_ending ~dir meta outcome);
      Ok ()
  | _ ->
      if Subrun.record_outcome ~dir id outcome then Ok ()
      else Error (Printf.sprintf "run %s already has an outcome, or is gone" id_str)

let%test_module "Tests" =
  (module struct
    open Test_fixture

    let id s = Result.get_exn (Subrun.parse_id s)

    let outcome ~dir run result =
      ignore (Subrun.record_outcome ~dir (id run) { result; text = ""; at = Some 1_700_000_090. })

    let show_outcome ~dir run =
      match Subrun.read_outcome ~dir (id run) with
      | None -> print_endline "no outcome"
      | Some o -> Printf.printf "outcome %s %S\n" (Subrun.string_of_result o.result) o.text

    let%expect_test "runs: the table newest first, one run shown, and --json" =
      let dir = Filename.temp_dir "kido-state" "" in
      ignore
        (run ~dir ~name:"kid" ~kind:Agent ~parent:"root" ~cwd:"/tmp/some project"
           ~started_at:1_700_000_000. "run-a");
      outcome ~dir "run-a" Completed;
      ignore
        (run ~dir ~name:"later" ~kind:Bash ~pid:(dead_pid ()) ~started_at:1_700_003_600. "run-b");
      let local out =
        List.fold_left
          (fun out (t, name) -> String.replace ~sub:(Timestamp.to_local_string t) ~by:name out)
          out
          [
            (1_700_000_000., "<started a>");
            (1_700_000_090., "<ended a>");
            (1_700_003_600., "<started b>");
          ]
      in
      (* Local time, whatever this machine's zone. *)
      table ~now:(Timestamp.now ()) (list ~dir ())
      |> List.iter (fun row ->
          List.filter (Fun.negate String.is_empty) row
          |> String.concat " | " |> local |> print_endline);
      print_string (local (Result.get_exn (show ~dir ~json:false "run-a")));
      [%expect
        {|
    ID | NAME | PARENT | STARTED | DURATION | OUTCOME | CWD
    run-b | later | <started b> | - | died
    run-a | kid | root | <started a> | 1m30s | completed | /tmp/some project
    id:       run-a
    name:     kid
    kind:     agent
    parent:   root
    depth:    1
    cwd:      /tmp/some project
    started:  <started a>
    outcome:  completed
    ended:    <ended a>
    resume:   cd '/tmp/some project' && kido tool spawn_subagent --resume run-a
    fork:     cd '/tmp/some project' && pi --fork run-a
    task:
    do the thing
    |}];
      let shown = Yojson.Safe.from_string (Result.get_exn (show ~dir ~json:true "run-a")) in
      let listed = `List (List.map yojson_of_info (list ~dir ())) in
      Yojson.Safe.Util.(
        print_endline (String.concat " " (keys shown));
        List.iter
          (fun r ->
            Printf.printf "%s %s\n"
              (to_string (member "id" r))
              (match member "outcome" r with
              | `Null -> "running"
              | o -> to_string (member "result" o)))
          (to_list listed));
      [%expect
        {|
    id name kind parentSession depth pane pid cwd startedAt outcome task resume fork
    run-b died
    run-a completed
    |}]

    let%expect_test "runs: filter by parent, still newest first" =
      let dir = Filename.temp_dir "kido-state" "" in
      ignore (run ~dir ~parent:"root" ~started_at:1. "old");
      ignore (run ~dir ~parent:"other" ~started_at:3. "other");
      ignore (run ~dir ~parent:"root" ~pid:(Unix.getpid ()) ~started_at:2. "new");
      outcome ~dir "old" Completed;
      list ~parent_session:"root" ~dir ()
      |> List.iter (fun (r : info) ->
          Printf.printf "%s %s\n" (Subrun.string_of_id r.meta.id)
            (Option.map_or ~default:"running"
               (fun o -> Subrun.string_of_result o.Subrun.result)
               r.outcome));
      [%expect {|
    new running
    old completed
    |}]

    let%expect_test "runs: running while the run's process lives, died once it is gone" =
      let dir = Filename.temp_dir "kido-state" "" in
      ignore (run ~dir ~pid:(Unix.getpid ()) "run-live");
      ignore (run ~dir ~pid:(dead_pid ()) "run-dead");
      List.concat_map
        (fun r ->
          String.lines (Result.get_exn (show ~dir ~json:false r))
          |> List.filter (String.prefix ~pre:"outcome:"))
        [ "run-live"; "run-dead" ]
      |> List.iter print_endline;
      [%expect {|
    outcome:  running
    outcome:  died
    |}]

    let record_outcome ~dir ?(unreported = false) result r =
      match
        run_outcome ~dir ~warn:(Printf.printf "warning: %s\n") ~result ~text:"" ~unreported r
      with
      | Ok () -> ()
      | Error m -> Printf.printf "refused: %s\n" m

    let%expect_test "run-outcome records one outcome, and only for a valid run id" =
      let dir = Filename.temp_dir "kido-state" "" in
      ignore (run ~dir ~pane:"%9" "run-x");
      show_outcome ~dir "run-x";
      record_outcome ~dir Completed "run-x";
      show_outcome ~dir "run-x";
      record_outcome ~dir Completed "run-x";
      record_outcome ~dir Completed "../escape";
      [%expect
        {|
    no outcome
    outcome completed ""
    refused: run run-x already has an outcome, or is gone
    refused: invalid run id "../escape"
    |}]

    (* The outcome write decides who speaks: without --unreported the child reported for itself, and a
   run already stopped from outside was spoken for by its stopper. *)
    let%expect_test "run-outcome --unreported tells the parent once, and only if it won the write" =
      let dir = Filename.temp_dir "kido-state" "" in
      let inbox, received = start_inbox ~reply:"ok\n" in
      ignore (State.record ~dir "root-sess" (session ~pane:"%2" ~inbox ()));
      let child r = ignore (run ~dir ~name:"ttyfix" ~kind:Agent ~parent:"root-sess" r) in
      child "run-told";
      record_outcome ~dir ~unreported:true Completed "run-told";
      child "run-self";
      record_outcome ~dir Completed "run-self";
      child "run-stopped";
      outcome ~dir "run-stopped" Stopped;
      record_outcome ~dir ~unreported:true Completed "run-stopped";
      List.iter (show_outcome ~dir) [ "run-told"; "run-self"; "run-stopped" ];
      List.iter
        (fun raw ->
          match Test_fixture.envelope raw with
          | Some e -> Printf.printf "%s from %s:\n%s\n" (e "kind") (e "from.name") (e "text")
          | None -> Printf.printf "not an envelope: %S\n" raw)
        (received ());
      [%expect
        {|
    outcome completed ""
    outcome completed ""
    outcome stopped ""
    notice from ttyfix:
    subagent "ttyfix" completed without reporting: it never called notify_parent, so this is the whole account of it
    run: run-told
    resume: spawn_subagent(resume: "run-told")
    |}]

    (* Go's time.Duration printing, which the table and stop's escalation message carry. *)
    let%expect_test "durations print as Go prints them" =
      List.iter
        (fun d -> Printf.printf "%g -> %s\n" d (Timestamp.duration d))
        [ 0.; 0.3; 1.; 1.5; 59.; 60.; 90.; 3600.; 3723.; 86400. ];
      [%expect
        {|
    0 -> 0s
    0.3 -> 300ms
    1 -> 1s
    1.5 -> 1.5s
    59 -> 59s
    60 -> 1m0s
    90 -> 1m30s
    3600 -> 1h0m0s
    3723 -> 1h2m3s
    86400 -> 24h0m0s
    |}]
  end)
