type info = { meta : Run.meta; outcome : Run.outcome option }

let yojson_of_info { meta; outcome } =
  Yojson.Safe.Util.combine (Run.yojson_of_meta meta)
    (`Assoc (Option.map_or ~default:[] (fun o -> [ ("outcome", Run.yojson_of_outcome o) ]) outcome))

let load ?owner ~dir id =
  Run.load ~dir id
  |> Option.filter (fun (r : Run.t) ->
      Option.for_all (fun o -> Option.equal Run.equal_id (Some o) r.meta.parent) owner)
  |> Option.map (fun (r : Run.t) ->
      { meta = { r.meta with name = Run.name r }; outcome = Run.effective_outcome ~dir r.meta })

let list ?owner ~dir () =
  List.filter_map (load ?owner ~dir) (Run.list ~dir)
  |> List.sort (fun a b -> Float.compare b.meta.started_at a.meta.started_at)

type detail = { info : info; task : string; screen : string option; report : string option }

let detail ~dir id =
  let open Result.Infix in
  let+ info =
    Option.to_result (Printf.sprintf "run %S: no such run" (Run.string_of_id id)) (load ~dir id)
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
      ignore (run ~dir ~parent:"root" ~started_at:1. "old");
      ignore (run ~dir ~parent:"other" ~started_at:3. "other");
      ignore (run ~dir ~parent:"root" ~pid:(Unix.getpid ()) ~started_at:2. "new");
      outcome ~dir "old" Completed;
      list ~owner:(run_id "root") ~dir ()
      |> List.iter (fun (r : info) ->
          Printf.printf "%s %s\n" (Run.string_of_id r.meta.id)
            (Option.map_or ~default:"running"
               (fun o -> Run.string_of_result o.Run.result)
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
               (fun o -> Run.string_of_result o.Run.result)
               (Result.get_exn (detail ~dir (run_id r))).info.outcome))
        [ "run-live"; "run-dead" ];
      [%expect {|
    running
    died
    |}]
  end)
