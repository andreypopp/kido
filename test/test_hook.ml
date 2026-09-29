open Kido

let input ?(session = "s") ?(notification = "") ?(trigger = "") ?(tool = "") ?(agent = "")
    ?(tasks = []) event : Hook.input =
  {
    event;
    session_id = session;
    notification_type = notification;
    trigger;
    tool_name = tool;
    agent_id = agent;
    background_tasks = List.map (fun status : Hook.task -> { status }) tasks;
  }

let show input ~parked =
  Printf.printf "%-18s parked=%-5b %s\n" input.Hook.event parked
    (Hook.describe input (Hook.apply input ~parked))

let%expect_test "apply" =
  List.iter
    (fun (i, parked) -> show i ~parked)
    [
      (input "SessionStart", false);
      (input "Stop", false);
      (input "Stop" ~tasks:[ "running" ], false);
      (input "Stop" ~tasks:[ "completed" ], false);
      (input "SubagentStop", true);
      (input "SubagentStop" ~tasks:[ "completed" ], true);
      (input "SubagentStop" ~tasks:[ "running" ], true);
      (input "SubagentStop", false);
      (input "PostToolUse", true);
      (input "UserPromptSubmit", true);
      (input "PostToolUse" ~agent:"a", true);
      (input "PreToolUse" ~tool:"AskUserQuestion", false);
      (input "PreToolUse" ~tool:"AskUserQuestion", true);
      (input "Notification" ~notification:"permission_prompt", false);
      (input "Notification" ~notification:"permission_prompt", true);
      (input "Notification" ~notification:"idle_prompt", false);
      (input "Notification" ~notification:"idle_prompt", true);
      (input "Notification" ~notification:"auth_success", false);
      (input "PermissionRequest", false);
      (input "PermissionRequest", true);
      (input "PreCompact" ~trigger:"auto", false);
      (input "PostCompact" ~trigger:"auto", false);
      (input "PostCompact" ~trigger:"manual", false);
      (input "SessionEnd", false);
      (input "Unknown", false);
      (input "Stop" ~session:"", false);
    ];
  [%expect
    {|
    SessionStart       parked=false status=idle
    Stop               parked=false ended
    Stop               parked=false status=running background
    Stop               parked=false ended
    SubagentStop       parked=true  ended
    SubagentStop       parked=true  ended
    SubagentStop       parked=true  ignore
    SubagentStop       parked=false ignore
    PostToolUse        parked=true  status=running
    UserPromptSubmit   parked=true  status=running
    PostToolUse        parked=true  status=running background
    PreToolUse         parked=false status=waiting
    PreToolUse         parked=true  status=waiting background
    Notification       parked=false status=waiting
    Notification       parked=true  status=waiting background
    Notification       parked=false ended
    Notification       parked=true  ignore
    Notification       parked=false ignore
    PermissionRequest  parked=false status=waiting
    PermissionRequest  parked=true  status=waiting background
    PreCompact         parked=false status=compacting
    PostCompact        parked=false status=running
    PostCompact        parked=false ended
    SessionEnd         parked=false remove
    Unknown            parked=false unmapped
    Stop               parked=false ignore
    |}]

let%expect_test "a tool call is pending from PreToolUse to PostToolUse" =
  List.iter
    (fun (i, parked) ->
      match Hook.apply i ~parked with
      | Report r ->
          Printf.printf "%s agent=%S parked=%b: pending=%b background=%b\n" i.event i.agent_id
            parked r.tool_pending r.background
      | _ -> print_endline "not a report")
    [
      (input "PreToolUse" ~tool:"Bash", false);
      (input "PreToolUse" ~tool:"Bash", true);
      (input "PreToolUse" ~tool:"Bash" ~agent:"a", true);
      (input "PreToolUse" ~tool:"Bash" ~agent:"a", false);
      (input "PostToolUse" ~tool:"Bash", false);
      (input "PreToolUse" ~tool:"AskUserQuestion", false);
      (input "UserPromptSubmit", false);
    ];
  [%expect
    {|
    PreToolUse agent="" parked=false: pending=true background=false
    PreToolUse agent="" parked=true: pending=true background=false
    PreToolUse agent="a" parked=true: pending=true background=true
    PreToolUse agent="a" parked=false: pending=true background=false
    PostToolUse agent="" parked=false: pending=false background=false
    PreToolUse agent="" parked=false: pending=false background=false
    UserPromptSubmit agent="" parked=false: pending=false background=false
    |}]

let%expect_test "a payload decodes, ignoring fields kido does not read" =
  {|{"hook_event_name":"Stop","session_id":"s","cwd":"/x","background_tasks":[{"status":"running","id":"b1"}]}|}
  |> Yojson.Safe.from_string |> Hook.input_of_yojson
  |> Result.iter (fun i -> show i ~parked:false);
  [%expect {| Stop               parked=false status=running background |}]
