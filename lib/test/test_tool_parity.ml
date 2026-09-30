let kido args =
  let err = Filename.temp_file "kido" "stderr" in
  let code =
    Sys.command
      (Printf.sprintf "env -i KIDO_STATE_DIR=%s ../../bin/main.exe %s </dev/null >/dev/null 2>%s"
         (Filename.quote (Filename.temp_dir "kido-state" ""))
         (String.concat " " (List.map Filename.quote args))
         err)
  in
  (code, List.hd (String.lines (Option.get_or ~default:"" (Kido.Fs.read err) ^ "\n")))

(* pi's own suite pins that tools.json names exactly the tools it registers; this pins that each
   invokes a subcommand of its own name. *)
let%expect_test "every pi tool has a kido subcommand of its name" =
  let tools =
    Yojson.Safe.(Util.convert_each Util.to_string (from_file "../../share/pi/testdata/tools.json"))
  in
  List.iter
    (fun tool ->
      if fst (kido [ "tool"; tool; "--help=plain" ]) <> 0 then
        Printf.printf "%s: no subcommand of its name\n" tool)
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
      [ "tool"; "message_agent"; "--"; "--help" ];
      [ "tool"; "message_agent"; "--"; "-weird" ];
      [ "tool"; "message_agent"; "--"; "-" ];
      [ "tool"; "message_agent" ];
      [ "tool"; "message_agent"; "a"; "b" ];
      [ "tool"; "ask_agent"; "--reply-to"; "x"; "target" ];
      [ "tool"; "message_agent"; "--id"; "x"; "target" ];
      [ "tool"; "message_agent"; "--kind"; "reply"; "target" ];
      [ "tool"; "notify_parent"; "peer" ];
      [ "prompt"; "bogus" ];
    ];
  [%expect
    {|
    tool message_agent -- --help: 1 no message given
    tool message_agent -- -weird: 1 no message given
    tool message_agent -- -: 1 no message given
    tool message_agent: 1 Usage: kido tool message_agent [--help] [--reply-to=ID] [OPTION]… TO
    tool message_agent a b: 1 Usage: kido tool message_agent [--help] [--reply-to=ID] [OPTION]… TO
    tool ask_agent --reply-to x target: 1 Usage: kido tool ask_agent [--help] [--id=ID] [OPTION]… TO
    tool message_agent --id x target: 1 Usage: kido tool message_agent [--help] [--reply-to=ID] [OPTION]… TO
    tool message_agent --kind reply target: 1 Usage: kido tool message_agent [--help] [--reply-to=ID] [OPTION]… TO
    tool notify_parent peer: 1 Usage: kido tool notify_parent [--help] [OPTION]…
    prompt bogus: 1 Usage: kido prompt [--help] [--window] [OPTION]…
    |}]
