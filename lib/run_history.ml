type info = {
  meta : Run.meta;
  outcome : Run.outcome option;
  session : string option;
  output : string;
}

let yojson_of_info { meta; outcome; session; output } =
  Yojson.Safe.Util.combine (Run.yojson_of_meta meta)
    (`Assoc
       (("session", `String (Option.value ~default:"" session))
       :: ("output", `String output)
       :: (match outcome with Some o -> [ ("outcome", Run.yojson_of_outcome o) ] | None -> [])))

let under parent (m : Run.meta) =
  match (parent, m.parent) with
  | None, _ -> true
  | Some p, Some q -> Run.equal_parent p q
  | Some _, None -> false

let load ?parent ~dir ~state id =
  Option.filter (fun (m : Run.meta) -> under parent m) (Run.read_meta ~dir id)
  |> Option.map (fun (meta : Run.meta) ->
      {
        meta;
        outcome = State.run_ending ~dir state meta;
        session =
          Option.bind (State.run_pane state meta) (fun p ->
              if Option.is_none p.dead_at then p.session else None);
        output = Run.output_path ~dir meta.id;
      })

let list ?parent ~dir ~state () =
  List.filter_map (load ?parent ~dir ~state) (Run.list ~dir)
  |> List.sort (fun a b -> Float.compare b.meta.started_at a.meta.started_at)

type detail = { info : info; screen : string option }

let detail ~dir ~state id =
  let open Result.Infix in
  let+ info =
    Option.to_result
      (Printf.sprintf "run %S: no such run" (Run.string_of_id id))
      (load ~dir ~state id)
  in
  { info; screen = Run.read_screen ~dir id }

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
