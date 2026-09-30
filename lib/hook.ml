type task = { status : string } [@@deriving of_yojson { strict = false }]

type input = {
  event : string; [@key "hook_event_name"] [@default ""]
  session_id : string; [@default ""]
  notification_type : string; [@default ""]
  trigger : string; [@default ""]
  tool_name : string; [@default ""]
  agent_id : string; [@default ""]
  background_tasks : task list; [@default []]
}
[@@deriving of_yojson { strict = false }]

type action =
  | Ignore
  | Remove
  | Ended
  | Report of { status : State.status; background : bool; tool_pending : bool }

type event =
  | Session_start
  | Session_end
  | User_prompt_submit
  | Pre_tool_use
  | Post_tool_use
  | Stop
  | Subagent_stop
  | Permission_request
  | Notification
  | Pre_compact
  | Post_compact

let event_of_name = function
  | "SessionStart" -> Some Session_start
  | "SessionEnd" -> Some Session_end
  | "UserPromptSubmit" -> Some User_prompt_submit
  | "PreToolUse" -> Some Pre_tool_use
  | "PostToolUse" -> Some Post_tool_use
  | "Stop" -> Some Stop
  | "SubagentStop" -> Some Subagent_stop
  | "PermissionRequest" -> Some Permission_request
  | "Notification" -> Some Notification
  | "PreCompact" -> Some Pre_compact
  | "PostCompact" -> Some Post_compact
  | _ -> None

let report ?(background = false) ?(tool_pending = false) status =
  Report { status; background; tool_pending }

let apply input ~parked =
  let running_task = List.exists (fun (t : task) -> String.equal t.status "running") in
  let working ?tool_pending () =
    report ?tool_pending ~background:(parked && not (String.is_empty input.agent_id)) Running
  in
  let blocked = report ~background:parked Waiting in
  match event_of_name input.event with
  | _ when String.is_empty input.session_id -> Ignore
  | None -> Ignore
  | Some Session_start -> report Idle
  | Some Session_end -> Remove
  | Some User_prompt_submit -> report Running
  | Some Post_tool_use -> working ()
  | Some Pre_tool_use when String.equal input.tool_name "AskUserQuestion" -> blocked
  | Some Pre_tool_use -> working ~tool_pending:true ()
  | Some Stop when running_task input.background_tasks -> report ~background:true Running
  | Some Stop -> Ended
  | Some Subagent_stop when parked && not (running_task input.background_tasks) -> Ended
  | Some Subagent_stop -> Ignore
  | Some Permission_request -> blocked
  | Some Notification -> (
      match input.notification_type with
      | "permission_prompt" | "elicitation_dialog" | "elicitation_url_dialog" | "agent_needs_input"
        ->
          blocked
      | "idle_prompt" when not parked -> Ended
      | _ -> Ignore)
  | Some Pre_compact -> report Compacting
  | Some Post_compact when String.equal input.trigger "manual" -> Ended
  | Some Post_compact -> report Running

let describe input = function
  | _ when Option.is_none (event_of_name input.event) -> "unmapped"
  | Ignore -> "ignore"
  | Remove -> "remove"
  | Ended -> "ended"
  | Report { status; background = true; _ } ->
      "status=" ^ State.string_of_status status ^ " background"
  | Report { status; _ } -> "status=" ^ State.string_of_status status
