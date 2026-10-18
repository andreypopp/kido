let member key row =
  match Yojson.Safe.Util.member key row with `String s -> s | `Null -> "" | _ -> ""

let rows_path = Fs.getenv "KIDO_FAKE_RUNS_FILE"
let rows () = Fake_common.read_rows "KIDO_FAKE_RUNS_FILE"

let write_rows rows =
  if not (String.is_empty rows_path) then
    Fs.write ~perm:0o644 rows_path (Yojson.Safe.to_string (`List rows))

let outcome row =
  match row with `Assoc fields -> List.assoc_opt ~eq:String.equal "outcome" fields | _ -> None

let with_outcome row result text =
  let fields = match row with `Assoc fields -> fields | _ -> [] in
  `Assoc (("outcome", `Assoc [ ("result", `String result); ("text", `String text) ]) :: fields)

let with_row id f =
  let found = ref None in
  let rows =
    List.map
      (fun row ->
        if String.equal (member "id" row) id then begin
          found := Some row;
          f row
        end
        else row)
      (rows ())
  in
  write_rows rows;
  !found

let positional argv = match argv with _command :: id :: _ -> id | _ -> ""

let after_double_dash argv =
  let rec go = function "--" :: rest -> rest | _ :: rest -> go rest | [] -> [] in
  go argv

let run_command output command =
  let env = Array.append [| "KIDO_RUN_OUTPUT=" ^ output |] (Unix.environment ()) in
  let fd_in = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
  let fd_out = Unix.openfile output [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o644 in
  let pid =
    Unix.create_process_env (List.hd command) (Array.of_list command) env fd_in fd_out fd_out
  in
  Unix.close fd_in;
  Unix.close fd_out;
  let _, status = Unix.waitpid [] pid in
  match status with
  | Unix.WEXITED 0 -> ("completed", "")
  | Unix.WEXITED n -> ("failed", Printf.sprintf "exit %d" n)
  | Unix.WSIGNALED n -> ("failed", Printf.sprintf "signal %d" n)
  | Unix.WSTOPPED n -> ("failed", Printf.sprintf "stopped %d" n)

let run () =
  let argv = Array.to_list Sys.argv |> List.tl in
  let command = match argv with command :: _ -> command | [] -> "" in
  match command with
  | "run-child" ->
      Fake_common.log "KIDO_FAKE_RUN_LOG" (`List (List.map (fun string -> `String string) argv));
      let run_id = Option.value ~default:"fake-run-id" (Sys.getenv_opt "KIDO_FAKE_RUN_ID") in
      Fake_common.wait_gate (Fs.getenv "KIDO_FAKE_RUN_GATE");
      let output = Fs.getenv "KIDO_FAKE_STATE_DIR" ^ "/runs/" ^ run_id ^ "/output" in
      Fs.mkdir_p ~perm:0o700 (Filename.dirname output);
      let parent = positional argv in
      let ending =
        if String.equal (Fs.getenv "KIDO_FAKE_RUN_EXEC") "1" then
          match after_double_dash argv with
          | [] -> None
          | command -> Some (run_command output command)
        else None
      in
      if not (String.is_empty rows_path) then begin
        let row =
          `Assoc
            [
              ("id", `String run_id);
              ("name", `String (Option.value ~default:"" (Fake_common.arg_after "--name" argv)));
              ("parent", `String parent);
              ("pane", `String "%9");
              ("output", `String output);
              ("startedAt", `String "2023-11-14T22:00:00Z");
            ]
        in
        write_rows
          (rows ()
          @ [
              (match ending with
              | None -> row
              | Some (result, text) -> with_outcome row result text);
            ])
      end;
      Printf.printf "{\"id\":%S,\"pane\":%S,\"output\":%S}\n" run_id "@9.%9" output;
      exit 0
  | "runs" ->
      Fake_common.log "KIDO_FAKE_RUNS_LOG" (`List (List.map (fun string -> `String string) argv));
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
        | None -> rows ()
        | Some parent ->
            List.filter (fun row -> String.equal (member "parent" row) parent) (rows ())
      in
      print_endline (Yojson.Safe.to_string (`List rows));
      exit 0
  | "run-wait" ->
      Fake_common.log "KIDO_FAKE_RUN_WAIT_LOG"
        (`List (List.map (fun string -> `String string) argv));
      Fake_common.wait_gate (Fs.getenv "KIDO_FAKE_RUN_WAIT_GATE");
      let id = positional argv in
      let stored =
        List.find_map
          (fun row -> if String.equal (member "id" row) id then outcome row else None)
          (rows ())
      in
      let answer =
        match Sys.getenv_opt "KIDO_FAKE_RUN_WAIT_OUTCOME" with
        | Some raw -> raw
        | None -> (
            match stored with
            | Some json -> Yojson.Safe.to_string json
            | None -> "{\"result\":\"completed\"}")
      in
      print_endline answer;
      flush stdout;
      let ready = Fs.getenv "KIDO_FAKE_RUN_WAIT_READY" in
      if not (String.is_empty ready) then Fs.write ~perm:0o644 ready "";
      Fake_common.wait_gate (Fs.getenv "KIDO_FAKE_RUN_WAIT_EXIT_GATE");
      exit 0
  | "run-stop" ->
      Fake_common.log "KIDO_FAKE_RUN_STOP_LOG"
        (`List (List.map (fun string -> `String string) argv));
      Fake_common.wait_gate (Fs.getenv "KIDO_FAKE_RUN_STOP_GATE");
      let cleanup = List.mem ~eq:String.equal "--cleanup" argv in
      let record_only = List.mem ~eq:String.equal "--record-only" argv in
      let result =
        if
          String.equal
            (Option.value ~default:"" (Fake_common.arg_after "--result" argv))
            "completed"
        then "completed"
        else "stopped"
      in
      let id = positional argv in
      let found = List.find_opt (fun row -> String.equal (member "id" row) id) (rows ()) in
      (match found with
      | None ->
          Printf.eprintf "run %s: no such run\n" id;
          exit 3
      | Some row ->
          if (not cleanup) && Option.is_some (outcome row) then begin
            Printf.eprintf "run %s has already ended\n" id;
            exit 5
          end;
          if not cleanup then ignore (with_row id (fun row -> with_outcome row result ""));
          if record_only then Printf.printf "recorded run %s\n" id
          else Printf.printf "stopped run %s; killed its pane\n" id);
      exit 0
  | "run-outcome" ->
      Fake_common.log "KIDO_FAKE_RUN_OUTCOME_LOG"
        (`List (List.map (fun string -> `String string) argv));
      let requested = Option.value ~default:"" (Fake_common.arg_after "--result" argv) in
      if not (List.mem ~eq:String.equal requested [ "completed"; "failed" ]) then begin
        Printf.eprintf "run-outcome: result must be completed or failed\n";
        exit 1
      end;
      let text = Option.value ~default:"" (Fake_common.arg_after "--text" argv) in
      let id = match List.rev (after_double_dash argv) with id :: _ -> id | [] -> "" in
      (match List.find_opt (fun row -> String.equal (member "id" row) id) (rows ()) with
      | None ->
          Printf.eprintf "run %s: no such run\n" id;
          exit 1
      | Some row ->
          if Option.is_some (outcome row) then begin
            Printf.eprintf "run %s already has an outcome\n" id;
            exit 1
          end;
          ignore (with_row id (fun row -> with_outcome row requested text)));
      exit 0
  | _ -> exit 1

let () = run ()
