type message_log = {
  kind : string;
  replyTo : string; [@key "replyTo"]
  id : string;
  to_ : string option; [@key "to"]
  text : string;
  failed : bool;
  args : string list;
}
[@@deriving yojson]

type spawn_log = { args : string list; task : string; caller : string option } [@@deriving yojson]

let json_of_strings strings = `List (List.map (fun string -> `String string) strings)
let env_truthy key = match Sys.getenv_opt key with None | Some "" -> false | Some _ -> true

let delay key =
  match Option.flat_map float_of_string_opt (Sys.getenv_opt key) with
  | Some ms -> Unix.sleepf (ms /. 1000.)
  | None -> ()

let append path text =
  if not (String.is_empty path) then
    Out_channel.with_open_gen [ Open_append; Open_creat ] 0o644 path (fun channel ->
        Out_channel.output_string channel text)

let log path json = append (Fs.getenv path) (Yojson.Safe.to_string json ^ "\n")
let member key = function `Assoc fields -> List.assoc_opt ~eq:String.equal key fields | _ -> None

let member_string key json =
  match member key json with Some (`String string) -> Some string | _ -> None

let session_equal session json =
  match (member_string "session" json, session) with
  | Some left, Some right -> String.equal left right
  | None, None -> true
  | _ -> false

let asks_of_file path =
  match Fs.read path with
  | Some raw -> ( match Yojson.Safe.from_string raw with `List asks -> asks | _ -> [])
  | None -> []

let last_arg args = match List.rev args with last :: _ -> Some last | [] -> None

let run () =
  let argv = Array.to_list Sys.argv |> List.tl in
  let args = match argv with "tool" :: rest -> rest | _ -> argv in
  let command = match args with command :: _ -> command | [] -> "" in
  let tool_names =
    [
      "list_runs";
      "message_agent";
      "ask_agent";
      "notify_parent";
      "steer_subagent";
      "interrupt_subagent";
      "stop_run";
      "set_status";
      "spawn_subagent";
      "async_bash";
      "set_asks";
    ]
  in
  if
    List.mem ~eq:String.equal command tool_names
    && match argv with "tool" :: _ -> false | _ -> true
  then exit 1;
  let command =
    if String.equal command "get-agent" && List.mem ~eq:String.equal "--context" args then
      "list_runs"
    else command
  in
  match command with
  | "get-asks" | "set_asks" | "remove-ask" ->
      let path = Filename.concat (Fs.getenv "KIDO_FAKE_STATE_DIR") "asks.json" in
      let asks = asks_of_file path in
      if String.equal command "get-asks" then (
        let index = List.find_index (String.equal "--session") args |> Option.get in
        let session = List.nth args (index + 1) in
        let snapshot =
          `List (List.filter (fun ask -> session_equal (Some session) ask) asks)
          |> Yojson.Safe.to_string
        in
        if Sys.file_exists (Filename.dirname path) then append (path ^ ".read") (snapshot ^ "\n");
        delay "KIDO_FAKE_ASKS_DELAY_MS";
        print_string snapshot;
        exit 0)
      else if String.equal command "set_asks" then (
        let session = Sys.getenv_opt "PI_SESSION_ID" in
        let entries =
          match Yojson.Safe.from_string (In_channel.input_all stdin) with
          | `List entries -> entries
          | _ -> []
        in
        let result =
          List.mapi
            (fun index entry ->
              let id =
                match member "id" entry with
                | Some (`String "") | None -> `String ("A" ^ string_of_int (7 + index))
                | Some id -> id
              in
              let text = Option.value ~default:`Null (member "text" entry) in
              `Assoc [ ("id", id); ("text", text) ])
            entries
        in
        Fs.mkdir_p (Filename.dirname path);
        Fs.write (path ^ ".setting") "";
        delay "KIDO_FAKE_SET_DELAY_MS";
        let others = List.filter (fun ask -> not (session_equal session ask)) asks in
        let kept =
          List.map
            (fun entry ->
              match entry with
              | `Assoc fields ->
                  `Assoc
                    (fields
                    @ [
                        ( "session",
                          match session with Some session -> `String session | None -> `Null );
                      ])
              | other -> other)
            result
        in
        Fs.write path (Yojson.Safe.to_string (`List (others @ kept)));
        print_string (Yojson.Safe.to_string (`List result));
        exit 0)
      else
        let kept =
          List.filter
            (fun ask ->
              match (member "id" ask, last_arg args) with
              | Some (`String id), Some last -> not (String.equal id last)
              | _ -> true)
            asks
        in
        Fs.write path (Yojson.Safe.to_string (`List kept));
        Fs.write (path ^ ".removed") (Yojson.Safe.to_string (json_of_strings argv));
        exit 0
  | "get-inbox" ->
      if String.equal (Fs.getenv "KIDO_FAKE_INBOX_FAIL") "1" then exit 1;
      let directory = Fs.getenv "KIDO_FAKE_INBOX_DIR" in
      let path = Filename.concat directory (List.nth args 1 ^ ".sock") in
      print_endline (Yojson.Safe.to_string (`Assoc [ ("path", `String path) ]));
      exit 0
  | "list_runs" ->
      log "KIDO_FAKE_AGENTS_CALL_LOG" (`String "1");
      delay "KIDO_FAKE_AGENTS_DELAY_MS";
      print_string
        (match Fs.read (Fs.getenv "KIDO_FAKE_AGENTS_FILE") with Some raw -> raw | None -> "[]");
      exit 0
  | "get-agent" ->
      let id = List.nth args 1 in
      log "KIDO_FAKE_PARENT_ALIVE_LOG" (json_of_strings argv);
      (* A named dead session answers "false" whatever the global mode says, so
         a test can kill one mid-run while an asker is waiting on it. *)
      let dead =
        match Fs.read (Fs.getenv "KIDO_FAKE_DEAD_FILE") with
        | Some raw ->
            String.split_on_char '\n' raw |> List.filter (fun line -> not (String.is_empty line))
        | None -> []
      in
      if List.mem ~eq:String.equal id dead then (
        print_endline
          (Yojson.Safe.to_string (`Assoc [ ("id", `String id); ("alive", `Bool false) ]));
        exit 0);
      let mode = Option.value ~default:"1" (Sys.getenv_opt "KIDO_FAKE_PARENT_ALIVE") in
      delay "KIDO_FAKE_PARENT_ALIVE_DELAY_MS";
      if String.equal mode "fail" then (
        prerr_string "kido get-agent: nope\n";
        exit 1);
      print_endline
        (Yojson.Safe.to_string
           (`Assoc [ ("id", `String id); ("alive", `Bool (String.equal mode "1")) ]));
      exit 0
  | "agent-status" ->
      let caller = Sys.getenv_opt "PI_SESSION_ID" in
      log "KIDO_FAKE_STATUS_LOG"
        (`List
           (List.map (fun string -> `String string) (argv @ [ "--caller" ])
           @ [ (match caller with Some caller -> `String caller | None -> `Null) ]));
      (* Logged first, so a test can tell "the claim was attempted and refused"
         from "nothing was ever sent". *)
      if env_truthy "KIDO_FAKE_SESSION_HELD" then (
        prerr_string
          ("session "
          ^ Option.value ~default:"undefined" caller
          ^ " is already open in pane %9 (pid 4242); this process is not tracked\n");
        exit 6);
      exit 0
  | "set_status" ->
      log "KIDO_FAKE_SET_STATUS_LOG" (json_of_strings argv);
      exit 0
  | ("message_agent" | "ask_agent" | "steer_subagent" | "notify_parent") as command ->
      let length = List.length args in
      let rec parse index reply_to message_id to_ =
        if index >= length then (reply_to, message_id, to_)
        else
          let value offset =
            if index + offset < length then List.nth args (index + offset) else ""
          in
          match List.nth args index with
          | "--reply-to" -> parse (index + 2) (value 1) message_id to_
          | "--id" -> parse (index + 2) reply_to (value 1) to_
          | "--" ->
              ( reply_to,
                message_id,
                if index + 1 < length then Some (List.nth args (index + 1)) else None )
          | _ -> parse (index + 1) reply_to message_id to_
      in
      let reply_to, message_id, to_ = parse 1 "" "" None in
      let kind, to_ =
        if String.equal command "ask_agent" then ("ask", to_)
        else if String.equal command "steer_subagent" then ("steer", to_)
        else if String.equal command "notify_parent" then
          ("notice", Sys.getenv_opt "KIDO_AGENT_PARENT_SESSION")
        else if not (String.is_empty reply_to) then ("reply", to_)
        else ("message", to_)
      in
      let text = In_channel.input_all stdin in
      let gate = Fs.getenv "KIDO_FAKE_MESSAGE_GATE" in
      (if not (String.is_empty gate) then
         let deadline = Unix.gettimeofday () +. 10. in
         while (not (Sys.file_exists gate)) && Float.(Unix.gettimeofday () < deadline) do
           Unix.sleepf 0.005
         done);
      delay "KIDO_FAKE_MESSAGE_DELAY_MS";
      let fail_to = Fs.getenv "KIDO_FAKE_MESSAGE_FAIL_TO" in
      let failed =
        (not (String.is_empty fail_to)) && Option.equal String.equal to_ (Some fail_to)
      in
      (* Logged either way: a test asserting a dropped delivery still needs to
         see the attempt was made, with the right kind and target. *)
      let entry = { kind; replyTo = reply_to; id = message_id; to_; text; failed; args = argv } in
      log "KIDO_FAKE_LOG" (yojson_of_message_log entry);
      if failed then (
        prerr_string ("kido tool " ^ command ^ ": no agent listening on the inbox\n");
        exit 1);
      print_string ("delivered to " ^ Option.value ~default:"null" to_ ^ " by inbox\n");
      exit 0
  | "spawn_subagent" ->
      let task = In_channel.input_all stdin in
      log "KIDO_FAKE_SPAWN_LOG"
        (yojson_of_spawn_log { args = argv; task; caller = Sys.getenv_opt "PI_SESSION_ID" });
      delay "KIDO_FAKE_SPAWN_DELAY_MS";
      print_string "@9 %9 fake-run-id\n";
      exit 0
  | "run-outcome" ->
      log "KIDO_FAKE_RUN_OUTCOME_LOG" (json_of_strings argv);
      exit 0
  | "interrupt_subagent" | "stop_run" ->
      log "KIDO_FAKE_CONTROL_LOG" (json_of_strings argv);
      print_string
        ((if String.equal command "interrupt_subagent" then "interrupted " else "stopped ")
        ^ Option.value ~default:"" (last_arg args)
        ^ "\n");
      exit 0
  | "async_bash" ->
      log "KIDO_FAKE_ASYNC_BASH_LOG" (json_of_strings argv);
      (* Four fields, the last the run's output file, exactly as
         Run_window.create writes them for a bash run. *)
      let run_id = "fake-async-run-id" in
      let output = Fs.getenv "KIDO_FAKE_STATE_DIR" ^ "/runs/" ^ run_id ^ "/output" in
      print_string ("@9 %9 " ^ run_id ^ " " ^ output ^ "\n");
      exit 0
  | _ -> exit 1

let () = run ()
