type info = { meta : Run.meta; outcome : Run.outcome option; session : string option }

let yojson_of_info { meta; outcome; session } =
  Yojson.Safe.Util.combine (Run.yojson_of_meta meta)
    (`Assoc
       (("session", `String (Option.value ~default:"" session))
       :: (match outcome with Some o -> [ ("outcome", Run.yojson_of_outcome o) ] | None -> [])))

let under parent (m : Run.meta) =
  match (parent, m.parent) with
  | None, _ -> true
  | Some p, Some q -> Run.equal_parent p q
  | Some _, None -> false

let load ?parent ~dir ~state id =
  Run.load ~dir id
  |> Option.filter (fun (r : Run.t) -> under parent r.meta)
  |> Option.map (fun (r : Run.t) ->
      {
        meta = { r.meta with name = Run.name r };
        outcome = State.run_ending ~dir state r.meta;
        session =
          Option.bind (State.run_pane state r.meta) (fun p ->
              if Option.is_none p.dead_at then p.session else None);
      })

let list ?parent ~dir ~state () =
  List.filter_map (load ?parent ~dir ~state) (Run.list ~dir)
  |> List.sort (fun a b -> Float.compare b.meta.started_at a.meta.started_at)

type detail = { info : info; task : string; screen : string option; report : string option }

let detail ~dir ~state id =
  let open Result.Infix in
  let+ info =
    Option.to_result
      (Printf.sprintf "run %S: no such run" (Run.string_of_id id))
      (load ~dir ~state id)
  in
  {
    info;
    task = Option.get_or ~default:"" (Run.read_task ~dir id);
    screen = Run.read_screen ~dir id;
    report = (if Run.has_report ~dir id then Some (Run.report_path ~dir id) else None);
  }

let%test_module "Tests" =
  (module struct
    open Test_fixture

    let outcome ~dir run result =
      ignore (Run.record_outcome ~dir (run_id run) { result; text = ""; at = Some 1_700_000_090. })

    let%expect_test "runs: filter by parent, still newest first" =
      let dir = Filename.temp_dir "kido-state" "" in
      ignore (run ~dir ~parent:"root" ~pane:"%9" ~started_at:1. "old");
      ignore (run ~dir ~parent:"other" ~started_at:3. "other");
      ignore (run ~dir ~parent:"root" ~pane:"%8" ~started_at:2. "new");
      outcome ~dir "old" Completed;
      let state = { State.empty with panes = [ pane ~run:"new" "%8" ] } in
      list ~parent:(Run.Run (run_id "root")) ~dir ~state ()
      |> List.iter (fun (r : info) ->
          Printf.printf "%s %s\n" (Run.string_of_id r.meta.id)
            (match r.outcome with Some o -> Run.string_of_result o.Run.result | None -> "running"));
      [%expect {|
    new running
    old completed
    |}]

    let%expect_test "runs: running while the run's process lives, died once it is gone" =
      let dir = Filename.temp_dir "kido-state" "" in
      ignore (run ~dir ~pane:"%7" "run-live");
      ignore (run ~dir ~pane:"%6" "run-dead");
      let state = { State.empty with panes = [ pane ~run:"run-live" "%7" ] } in
      List.iter
        (fun r ->
          print_endline
            (match (Result.get_exn (detail ~dir ~state (run_id r))).info.outcome with
            | Some o -> Run.string_of_result o.Run.result
            | None -> "running"))
        [ "run-live"; "run-dead" ];
      [%expect {|
    running
    died
    |}]
  end)
