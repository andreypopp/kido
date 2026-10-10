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

let list ?parent_session ~dir () =
  List.filter_map (load ?parent_session ~dir) (Subrun.list ~dir)
  |> List.sort (fun a b -> Float.compare b.meta.started_at a.meta.started_at)

type detail = { info : info; task : string; screen : string option; report : string option }

let detail ~dir id_str =
  let open Result.Infix in
  let* id = Subrun.parse_id id_str in
  let+ info = Option.to_result (Printf.sprintf "run %S: no such run" id_str) (load ~dir id) in
  {
    info;
    task = Option.get_or ~default:"" (Subrun.read_task ~dir id);
    screen = Subrun.read_screen ~dir id;
    report = (if Subrun.has_report ~dir id then Some (Subrun.report_path ~dir id) else None);
  }

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
      List.iter
        (fun r ->
          print_endline
            (Option.map_or ~default:"running"
               (fun o -> Subrun.string_of_result o.Subrun.result)
               (Result.get_exn (detail ~dir r)).info.outcome))
        [ "run-live"; "run-dead" ];
      [%expect {|
    running
    died
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
  end)
