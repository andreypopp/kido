package hook

import (
	"testing"

	"kido/internal/state"
)

// tasks builds an Input's background_tasks from the statuses it should
// report, the field being an anonymous struct.
func tasks(statuses ...string) []struct {
	Status string `json:"status"`
} {
	out := make([]struct {
		Status string `json:"status"`
	}, len(statuses))
	for i, s := range statuses {
		out[i].Status = s
	}
	return out
}

func TestApply(t *testing.T) {
	inTool := Report{Status: state.Running, ToolPending: true}
	backgroundedInTool := Report{Status: state.Running, Background: true, ToolPending: true}

	for _, c := range []struct {
		in     Input
		parked bool
		want   Effect
	}{
		{Input{Event: "SessionStart", SessionID: "s"}, false, idle},
		{Input{Event: "Stop", SessionID: "s"}, false, ended},
		{Input{Event: "Stop", SessionID: "s", BackgroundTasks: tasks("running")}, false, backgrounded},
		{Input{Event: "Stop", SessionID: "s", BackgroundTasks: tasks("completed")}, false, ended},
		{Input{Event: "Stop", SessionID: "s", BackgroundTasks: tasks()}, false, ended},
		{Input{Event: "SubagentStop", SessionID: "s"}, true, ended},
		{Input{Event: "SubagentStop", SessionID: "s", BackgroundTasks: tasks("completed")}, true, ended},
		{Input{Event: "SubagentStop", SessionID: "s", BackgroundTasks: tasks("running")}, true, ignore},
		{Input{Event: "SubagentStop", SessionID: "s", BackgroundTasks: tasks()}, false, ignore},
		{Input{Event: "SubagentStop", SessionID: "s", BackgroundTasks: tasks("running")}, false, ignore},
		{Input{Event: "PreToolUse", SessionID: "s", ToolName: "Bash"}, false, inTool},
		{Input{Event: "PreToolUse", SessionID: "s", ToolName: "Bash"}, true, inTool},
		{Input{Event: "PostToolUse", SessionID: "s"}, true, running},
		{Input{Event: "UserPromptSubmit", SessionID: "s"}, true, running},
		{Input{Event: "PreToolUse", SessionID: "s", ToolName: "Bash", AgentID: "a"}, true, backgroundedInTool},
		{Input{Event: "PostToolUse", SessionID: "s", AgentID: "a"}, true, backgrounded},
		{Input{Event: "PreToolUse", SessionID: "s", ToolName: "Bash", AgentID: "a"}, false, inTool},
		{Input{Event: "PreToolUse", SessionID: "s", ToolName: "AskUserQuestion"}, false, waiting},
		{Input{Event: "Notification", SessionID: "s", NotificationType: "permission_prompt"}, false, waiting},
		{Input{Event: "Notification", SessionID: "s", NotificationType: "idle_prompt"}, false, ended},
		{Input{Event: "Notification", SessionID: "s", NotificationType: "idle_prompt"}, true, ignore},
		{Input{Event: "Notification", SessionID: "s", NotificationType: "permission_prompt"}, true, Report{Status: state.Waiting, Background: true}},
		{Input{Event: "PermissionRequest", SessionID: "s"}, true, Report{Status: state.Waiting, Background: true}},
		{Input{Event: "PreToolUse", SessionID: "s", ToolName: "AskUserQuestion"}, true, Report{Status: state.Waiting, Background: true}},
		{Input{Event: "PermissionRequest", SessionID: "s"}, false, waiting},
		{Input{Event: "Notification", SessionID: "s", NotificationType: "auth_success"}, false, ignore},
		{Input{Event: "PreCompact", SessionID: "s", Trigger: "auto"}, false, compacting},
		{Input{Event: "PostCompact", SessionID: "s", Trigger: "auto"}, false, running},
		{Input{Event: "PostCompact", SessionID: "s", Trigger: "manual"}, false, ended},
		{Input{Event: "SessionEnd", SessionID: "s"}, false, Remove{}},
		{Input{Event: "Unknown", SessionID: "s"}, false, ignore},
		{Input{Event: "Stop"}, false, ignore},
	} {
		if got := Apply(c.in, c.parked); got != c.want {
			t.Errorf("%+v parked=%v: got %+v want %+v", c.in, c.parked, got, c.want)
		}
	}
	if got := Apply(Input{Event: "Stop", SessionID: "s"}, false).(Report).Status; got != state.Idle {
		t.Errorf("Stop status = %v", got)
	}
	if n := len(Events()); n != 11 {
		t.Errorf("registered events = %d, want 11", n)
	}
}

func TestDescribe(t *testing.T) {
	for _, c := range []struct {
		event string
		e     Effect
		want  string
	}{
		{"FileChanged", ignore, "unmapped"},
		{"SessionEnd", Remove{}, "remove"},
		{"Stop", ended, "ended"},
		{"Notification", ignore, "ignore"},
		{"Stop", running, "status=running"},
		{"Stop", backgrounded, "status=running background"},
		{"SubagentStop", ignore, "ignore"},
	} {
		if got := Describe(c.event, c.e); got != c.want {
			t.Errorf("Describe(%q, %+v) = %q, want %q", c.event, c.e, got, c.want)
		}
	}
}

// TestToolPendingSpansTheToolCall pins that PreToolUse sets ToolPending
// and PostToolUse clears it; AskUserQuestion is not a tool call in this
// sense, since it blocks on the user instead.
func TestToolPendingSpansTheToolCall(t *testing.T) {
	for _, tc := range []struct {
		name  string
		in    Input
		want  bool
		state string
	}{
		{"PreToolUse opens it", Input{SessionID: "s1", Event: "PreToolUse", ToolName: "Bash"}, true, "running"},
		{"PostToolUse closes it", Input{SessionID: "s1", Event: "PostToolUse", ToolName: "Bash"}, false, "running"},
		{"AskUserQuestion is not a tool call", Input{SessionID: "s1", Event: "PreToolUse", ToolName: "AskUserQuestion"}, false, "waiting"},
		{"a prompt starts a turn, not a tool", Input{SessionID: "s1", Event: "UserPromptSubmit"}, false, "running"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := Apply(tc.in, false).(Report)
			if e.ToolPending != tc.want {
				t.Errorf("ToolPending = %v, want %v", e.ToolPending, tc.want)
			}
			if string(e.Status) != tc.state {
				t.Errorf("Status = %q, want %q", e.Status, tc.state)
			}
		})
	}
}
