let run () =
  let argv = Array.to_list Sys.argv |> List.tl in
  let command = match argv with command :: _ -> command | [] -> "" in
  match command with
  | "run-child" ->
      Fake_common.log "KIDO_FAKE_RUN_LOG" (`List (List.map (fun string -> `String string) argv));
      Fake_common.wait_gate (Fs.getenv "KIDO_FAKE_RUN_GATE");
      let run_id = Option.value ~default:"fake-run-id" (Sys.getenv_opt "KIDO_FAKE_RUN_ID") in
      let arg_after flag = Option.value ~default:"" (Fake_common.arg_after flag argv) in
      let output = Fs.getenv "KIDO_FAKE_STATE_DIR" ^ "/runs/" ^ run_id ^ "/output" in
      let rows_path = Fs.getenv "KIDO_FAKE_RUNS_FILE" in
      if not (String.is_empty rows_path) then begin
        let rows = Fake_common.read_rows "KIDO_FAKE_RUNS_FILE" in
        let parent = match argv with "run-child" :: p :: _ -> p | _ -> "" in
        let row =
          `Assoc
            [
              ("id", `String run_id);
              ("name", `String (arg_after "--name"));
              ("parent", `String parent);
              ("pane", `String "@9.%9");
              ("output", `String output);
              ("session", `String (arg_after "--session-id"));
              ("startedAt", `String "2023-11-14T22:00:00Z");
            ]
        in
        Fs.write ~perm:0o644 rows_path (Yojson.Safe.to_string (`List (rows @ [ row ])))
      end;
      Printf.printf "{\"id\":%S,\"pane\":%S,\"output\":%S}\n" run_id "@9.%9" output;
      exit 0
  | "runs" ->
      Fake_common.log "KIDO_FAKE_RUNS_LOG" (`List (List.map (fun string -> `String string) argv));
      let rows = Fake_common.read_rows "KIDO_FAKE_RUNS_FILE" in
      let member key row =
        match Yojson.Safe.Util.member key row with `String s -> s | `Null -> "" | _ -> ""
      in
      let parent = ref None in
      let rec parse = function
        | [] -> ()
        | "--parent" :: value :: rest ->
            parent := Some value;
            parse rest
        | "--json" :: rest -> parse rest
        | _ :: rest -> parse rest
      in
      parse (List.tl argv);
      let rows =
        match !parent with
        | None -> rows
        | Some parent -> List.filter (fun row -> String.equal (member "parent" row) parent) rows
      in
      print_endline (Yojson.Safe.to_string (`List rows));
      exit 0
  | "run-wait" ->
      Fake_common.log "KIDO_FAKE_RUN_WAIT_LOG"
        (`List (List.map (fun string -> `String string) argv));
      Fake_common.wait_gate (Fs.getenv "KIDO_FAKE_RUN_WAIT_GATE");
      print_endline
        (Option.value ~default:"{\"result\":\"completed\"}"
           (Sys.getenv_opt "KIDO_FAKE_RUN_WAIT_OUTCOME"));
      exit 0
  | "run-stop" ->
      Fake_common.log "KIDO_FAKE_RUN_STOP_LOG"
        (`List (List.map (fun string -> `String string) argv));
      let last = match List.rev argv with last :: _ -> last | [] -> "" in
      print_endline ("stopped run " ^ last ^ "; killed its pane");
      exit 0
  | "run-outcome" ->
      Fake_common.log "KIDO_FAKE_RUN_OUTCOME_LOG"
        (`List (List.map (fun string -> `String string) argv));
      exit 0
  | _ -> exit 1

let () = run ()
