let kido args =
  let err = Filename.temp_file "kido" "stderr" in
  let code =
    Sys.command
      (Printf.sprintf "env -i KIDO_STATE_DIR=%s ../bin/main.exe %s </dev/null >/dev/null 2>%s"
         (Filename.quote (Filename.temp_dir "kido-state" ""))
         (String.concat " " (List.map Filename.quote args))
         err)
  in
  (code, List.hd (String.lines (Option.get_or ~default:"" (Kido.Fs.read err) ^ "\n")))

(* Tools whose subcommand has not been ported yet; a name leaves this list with its port. *)
let pending = [ "steer_subagent"; "interrupt_subagent"; "stop_subagent" ]

(* pi's own suite pins that tools.json names exactly the tools it registers; this pins that each
   invokes a subcommand of its own name. *)
let%expect_test "every pi tool has a kido subcommand of its name" =
  let tools =
    Yojson.Safe.(Util.convert_each Util.to_string (from_file "../pi/testdata/tools.json"))
  in
  List.iter
    (fun tool ->
      let exists = fst (kido [ tool; "--help=plain" ]) = 0 in
      let is_pending = List.mem ~eq:String.equal tool pending in
      if Bool.equal exists is_pending then
        Printf.printf "%s: %s\n" tool
          (if exists then "ported: drop it from pending" else "no subcommand of its name"))
    tools;
  Printf.printf "%d tools\n" (List.length tools);
  [%expect {| 10 tools |}]

(* pi passes "--" before a model-authored target; the stdin being empty proves kido got past
   argument parsing with the target as a positional. *)
let%expect_test "a target named like a flag after -- is a target; a misstated kind is refused" =
  List.iter
    (fun args ->
      let code, err = kido args in
      Printf.printf "%s: %d %s\n" (String.concat " " args) code err)
    [
      [ "message_agent"; "--"; "--help" ];
      [ "message_agent"; "--"; "-weird" ];
      [ "message_agent"; "--"; "-" ];
      [ "message_agent" ];
      [ "message_agent"; "a"; "b" ];
      [ "ask_agent"; "--reply-to"; "x"; "target" ];
      [ "message_agent"; "--id"; "x"; "target" ];
      [ "message_agent"; "--kind"; "reply"; "target" ];
      [ "notify_parent"; "peer" ];
      [ "prompt"; "bogus" ];
    ];
  [%expect
    {|
    message_agent -- --help: 1 no message given
    message_agent -- -weird: 1 no message given
    message_agent -- -: 1 no message given
    message_agent: 1 Usage: kido message_agent [--help] [--reply-to=ID] [OPTION]… TO
    message_agent a b: 1 Usage: kido message_agent [--help] [--reply-to=ID] [OPTION]… TO
    ask_agent --reply-to x target: 1 Usage: kido ask_agent [--help] [--id=ID] [OPTION]… TO
    message_agent --id x target: 1 Usage: kido message_agent [--help] [--reply-to=ID] [OPTION]… TO
    message_agent --kind reply target: 1 Usage: kido message_agent [--help] [--reply-to=ID] [OPTION]… TO
    notify_parent peer: 1 Usage: kido notify_parent [--help] [OPTION]…
    prompt bogus: 1 Usage: kido prompt [--help] [--window] [OPTION]…
    |}]
