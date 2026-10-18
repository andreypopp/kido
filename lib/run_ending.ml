type detail = Bash | Streamed of { unstreamed : int } | Agent of { unreported : bool }
type ending = { meta : Run.meta; outcome : Run.outcome; detail : detail }

let quote s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\t' -> Buffer.add_string b "\\t"
      | c when Char.code c < 0x20 || Char.code c = 0x7f ->
          Buffer.add_string b (Printf.sprintf "\\x%02x" (Char.code c))
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b

let body ~dir e =
  let b = Buffer.create 256 in
  let result = Run.string_of_result e.outcome.result in
  (match e.detail with
  | (Bash | Streamed _) as detail -> (
      let output = Run.output_path ~dir e.meta.id in
      Printf.bprintf b "async run %s %s: %s\n" (quote (Run.label e.meta)) result e.outcome.text;
      Printf.bprintf b "run: %s\n" (Run.string_of_id e.meta.id);
      Printf.bprintf b "output: %s\n" output;
      match detail with
      | Streamed { unstreamed } ->
          if unstreamed > 0 then
            Printf.bprintf b "%d lines not streamed (the output file above has every one)\n"
              unstreamed
      | _ -> (
          let cap = Msg.max_notice_bytes in
          match
            let ic = open_in_bin output in
            Fun.protect
              ~finally:(fun () -> close_in ic)
              (fun () ->
                let size = in_channel_length ic in
                let omitted = if size > cap then size - cap else 0 in
                seek_in ic omitted;
                let b = really_input_string ic (size - omitted) in
                let skip =
                  if omitted > 0 then String.drop_while (fun c -> Char.code c land 0xC0 = 0x80) b
                  else b
                in
                (Msg.valid_utf_8 skip, omitted + String.length b - String.length skip))
          with
          | exception Sys_error err -> Printf.bprintf b "--- output unreadable: %s ---" err
          | "", _ -> Buffer.add_string b "--- no output ---"
          | tail, omitted when omitted > 0 ->
              Printf.bprintf b "--- last %d bytes of output (%d omitted) ---\n%s"
                (String.length tail) omitted tail
          | tail, _ -> Printf.bprintf b "--- output ---\n%s" tail))
  | Agent { unreported } ->
      if unreported then
        Printf.bprintf b
          "subagent %s %s without reporting: it never called notify_parent, so this is the whole \
           account of it\n"
          (quote (Run.label e.meta))
          result
      else
        Printf.bprintf b
          "subagent %s ended without recording an outcome of its own, so kido recorded it as %s; \
           whether it called notify_parent is not known, and any report it sent stands\n"
          (quote (Run.label e.meta))
          result;
      if not (String.is_empty e.outcome.text) then Printf.bprintf b "detail: %s\n" e.outcome.text;
      Printf.bprintf b "run: %s\n" (Run.string_of_id e.meta.id);
      Printf.bprintf b "resume: spawn_subagent(resume: %s)\n" (quote (Run.string_of_id e.meta.id)));
  Buffer.contents b

let send ~dir (e : ending) =
  let e =
    {
      e with
      meta = { e.meta with name = Run.name { meta = e.meta; pi = Run.read_pi ~dir e.meta.id } };
    }
  in
  let deliver ~path =
    Msg.deliver_envelope ~path
      {
        kind = Notice;
        id = Msg.new_id ();
        from = { session = ""; name = Run.label e.meta; pane = None };
        reply_to = "";
        text = body ~dir e;
        run = "";
        output = "";
      }
  in
  match e.meta.parent with
  | None -> Ok ()
  | Some (Run parent) -> (
      match Run.live_parent ~dir parent with
      | Error m -> Error (Msg.Failed m)
      | Ok { inbox = ""; _ } ->
          Error (Unavailable (Printf.sprintf "session %s has no inbox" (Run.string_of_id parent)))
      | Ok target -> deliver ~path:target.inbox)
  | Some (Pane pane) -> (
      match State.read ~dir (Tmux.create ()) with
      | Error m -> Error (Msg.Failed m)
      | Ok state -> (
          match State.find state pane with
          | None ->
              Error (Unavailable (Printf.sprintf "pane %s is gone" (Tmux.string_of_pane_id pane)))
          | Some p -> (
              match p.inbox with
              | Some inbox -> deliver ~path:inbox
              | None ->
                  Error
                    (Unavailable
                       (Printf.sprintf "pane %s has no inbox" (Tmux.string_of_pane_id pane))))))

let stop_result ~dir (meta : Run.meta) =
  match meta.kind with
  | Run.Agent when Run.has_report ~dir meta.id -> Run.Completed
  | Agent | Bash | Stream | Pi -> Stopped

let record_ending ?detail ~dir (meta : Run.meta) outcome =
  if not (Run.record_outcome ~dir meta.id outcome) then None
  else
    let detail =
      match detail with
      | Some detail -> detail
      | None -> (
          match meta.kind with
          | Run.Bash | Stream -> Bash
          | Pi | Agent -> Agent { unreported = false })
    in
    Some { meta; outcome; detail }

(* pi prints this and exits 0 when it cannot resolve a provider for the model it was given: the one
   line that names why no turn ever ran. Matched by substring, since it is pi's wording. *)
let login_line = "Use /login to log into a provider via OAuth or API key"

let refine_no_turn_detail text screen =
  if String.mem ~sub:"no turn ever ran" text && String.mem ~sub:login_line screen then
    Printf.sprintf "%s (the pane showed: \"%s\")" text login_line
  else text

let run_outcome ~dir ~warn ~result ~text id =
  let meta = Run.read_meta ~dir id in
  let text =
    match (meta, result) with
    | Some m, Run.Failed -> (
        match Run.save_screen (Tmux.create ()) ~dir id m.pane with
        | Some x -> refine_no_turn_detail text x
        | None -> text)
    | _ -> text
  in
  let outcome : Run.outcome = { result; text; at = Some (Timestamp.now ()) } in
  match meta with
  | Some ({ kind = Run.Agent; _ } as meta) when not (Run.has_report ~dir id) ->
      Option.iter
        (fun e ->
          Result.iter_err
            (fun err -> warn (Msg.string_of_error err))
            (send ~dir { e with detail = Agent { unreported = true } }))
        (record_ending ~dir meta outcome);
      Ok ()
  | _ ->
      if Run.record_outcome ~dir id outcome then Ok ()
      else Error (Printf.sprintf "run %s already has an outcome, or is gone" (Run.string_of_id id))

let%test_module "Tests" =
  (module struct
    open Test_fixture

    let%expect_test "a bash ending's notice carries the run's name, status, id and output tail" =
      let dir = Filename.temp_dir "kido-ending" "" in
      let meta = run ~dir ~kind:Bash ~name:"build" "run-named" in
      let i = meta.id in
      Fs.write (Run.output_path ~dir i) "boom\n";
      let emit e = print_string (String.replace ~sub:dir ~by:"DIR" (body ~dir e)) in
      emit { meta; outcome = { result = Failed; text = "exit status 3"; at = None }; detail = Bash };
      emit
        {
          meta = { meta with name = "" };
          outcome = { result = Completed; text = "exit status 0"; at = None };
          detail = Bash;
        };
      emit
        {
          meta;
          outcome = { result = Completed; text = "exit status 0"; at = None };
          detail = Streamed { unstreamed = 2 };
        };
      emit
        {
          meta;
          outcome = { result = Completed; text = "exit status 0"; at = None };
          detail = Streamed { unstreamed = 0 };
        };
      Fs.remove (Run.output_path ~dir i);
      print_string
        (body ~dir { meta; outcome = { result = Failed; text = "x"; at = None }; detail = Bash }
        |> String.split_on_char '\n' |> List.last_opt |> Option.get_exn_or "line"
        |> String.replace ~sub:dir ~by:"DIR");
      [%expect
        {|
    async run "build" failed: exit status 3
    run: run-named
    output: DIR/runs/run-named/output
    --- output ---
    boom
    async run "run-named" completed: exit status 0
    run: run-named
    output: DIR/runs/run-named/output
    --- output ---
    boom
    async run "build" completed: exit status 0
    run: run-named
    output: DIR/runs/run-named/output
    2 lines not streamed (the output file above has every one)
    async run "build" completed: exit status 0
    run: run-named
    output: DIR/runs/run-named/output
    --- output unreadable: DIR/runs/run-named/output: No such file or directory ---
    |}]

    let%expect_test "an agent ending's notice, reported and unreported" =
      let dir = Filename.temp_dir "kido-ending" "" in
      let meta = run ~dir ~parent:"root-sess" ~name:"kid" "run-agent" in
      print_string
        (body ~dir
           {
             meta;
             outcome = { result = Died; text = ""; at = None };
             detail = Agent { unreported = false };
           });
      print_string
        (body ~dir
           {
             meta;
             outcome = { result = Stopped; text = "killed by stop_run"; at = None };
             detail = Agent { unreported = true };
           });
      [%expect
        {|
    subagent "kid" ended without recording an outcome of its own, so kido recorded it as died; whether it called notify_parent is not known, and any report it sent stands
    run: run-agent
    resume: spawn_subagent(resume: "run-agent")
    subagent "kid" stopped without reporting: it never called notify_parent, so this is the whole account of it
    detail: killed by stop_run
    run: run-agent
    resume: spawn_subagent(resume: "run-agent")
    |}]

    (* The tail is cut at Msg.max_notice_bytes; a character the cut splits is dropped whole. *)
    let%expect_test "a bash notice keeps the output's tail, whole characters only" =
      let dir = Filename.temp_dir "kido-ending" "" in
      let meta = run ~dir ~kind:Bash ~name:"build" "run-tail" in
      let i = meta.id in
      let tail output =
        Fs.write (Run.output_path ~dir i) output;
        match
          body ~dir
            {
              meta;
              outcome = { result = Completed; text = "exit status 0"; at = None };
              detail = Bash;
            }
          |> String.lines |> List.drop 3
        with
        | header :: first :: rest ->
            Printf.printf "%s %S..%S\n" header (String.take 12 first)
              (List.last_opt rest |> Option.get_or ~default:first |> String.rev |> String.take 12
             |> String.rev)
        | lines -> List.iter print_endline lines
      in
      tail (String.concat "" (List.init 1000 (Printf.sprintf "line %04d\n")));
      tail "all of it\n";
      List.iter
        (fun keep -> tail ("ab\xf0\x9f\x8e\x89cd" ^ String.make (Msg.max_notice_bytes - keep) 'x'))
        [ 3; 4; 5; 6 ];
      tail (String.repeat "\xe2\x98\x83" ((Msg.max_notice_bytes / 3) + 1));
      [%expect
        {|
    --- last 4000 bytes of output (6000 omitted) --- "line 0600".."line 0999"
    --- output --- "all of it".."all of it"
    --- last 3999 bytes of output (6 omitted) --- "cdxxxxxxxxxx".."xxxxxxxxxxxx"
    --- last 3998 bytes of output (6 omitted) --- "cdxxxxxxxxxx".."xxxxxxxxxxxx"
    --- last 3997 bytes of output (6 omitted) --- "cdxxxxxxxxxx".."xxxxxxxxxxxx"
    --- last 4000 bytes of output (2 omitted) --- "\240\159\142\137cdxxxxxx".."xxxxxxxxxxxx"
    --- last 3999 bytes of output (3 omitted) --- "\226\152\131\226\152\131\226\152\131\226\152\131".."\226\152\131\226\152\131\226\152\131\226\152\131"
    |}]

    let show_outcome ~dir run =
      match Run.read_outcome ~dir (run_id run) with
      | None -> print_endline "no outcome"
      | Some o -> Printf.printf "outcome %s %S\n" (Run.string_of_result o.result) o.text

    let record_outcome ~dir result r =
      match
        Result.flat_map
          (run_outcome ~dir ~warn:(Printf.printf "warning: %s\n") ~result ~text:"")
          (Run.parse_id r)
      with
      | Ok () -> ()
      | Error m -> Printf.printf "refused: %s\n" m

    let%expect_test "run-outcome records one outcome, and only for a valid run id" =
      let dir = Filename.temp_dir "kido-state" "" in
      ignore (run ~dir ~pane:"%9" "run-x");
      Run.write_report ~dir (run_id "run-x") "the report";
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

    (* The outcome write decides who speaks: a run whose report is on record was spoken for by the
   child itself, and a run already stopped from outside was spoken for by its stopper. *)
    let%expect_test
        "run-outcome tells the parent once for an unreported run, and only if it won the write" =
      let dir = Filename.temp_dir "kido-state" "" in
      let inbox, received = start_inbox ~reply:"ok\n" in
      holding ~dir ~inbox "root-sess";
      let child r = ignore (run ~dir ~name:"ttyfix" ~kind:Agent ~parent:"root-sess" r) in
      child "run-told";
      record_outcome ~dir Completed "run-told";
      child "run-self";
      Run.write_report ~dir (run_id "run-self") "the report";
      record_outcome ~dir Completed "run-self";
      child "run-stopped";
      ignore
        (Run.record_outcome ~dir (run_id "run-stopped")
           { result = Stopped; text = ""; at = Some 1_700_000_090. });
      record_outcome ~dir Completed "run-stopped";
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
