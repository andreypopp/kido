package hook

import (
	"testing"

	"kido/internal/state"
)

func TestApply(t *testing.T) {
	for _, c := range []struct {
		in   Input
		want Effect
	}{
		{Input{Event: "SessionStart", SessionID: "s"}, idle},
		{Input{Event: "Stop", SessionID: "s"}, ended},
		{Input{Event: "Stop", SessionID: "s", BackgroundTasks: []struct {
			Status string `json:"status"`
		}{{Status: "running"}}}, running},
		{Input{Event: "Stop", SessionID: "s", BackgroundTasks: []struct {
			Status string `json:"status"`
		}{{Status: "completed"}}}, ended},
		{Input{Event: "Stop", SessionID: "s", BackgroundTasks: []struct {
			Status string `json:"status"`
		}{}}, ended},
		{Input{Event: "PreToolUse", SessionID: "s", ToolName: "Bash"}, running},
		{Input{Event: "PreToolUse", SessionID: "s", ToolName: "AskUserQuestion"}, waiting},
		{Input{Event: "Notification", SessionID: "s", NotificationType: "permission_prompt"}, waiting},
		{Input{Event: "Notification", SessionID: "s", NotificationType: "idle_prompt"}, ended},
		{Input{Event: "Notification", SessionID: "s", NotificationType: "auth_success"}, ignore},
		{Input{Event: "PreCompact", SessionID: "s", Trigger: "auto"}, compacting},
		{Input{Event: "PostCompact", SessionID: "s", Trigger: "auto"}, running},
		{Input{Event: "PostCompact", SessionID: "s", Trigger: "manual"}, ended},
		{Input{Event: "SessionEnd", SessionID: "s"}, Effect{Remove: true}},
		{Input{Event: "Unknown", SessionID: "s"}, ignore},
		{Input{Event: "Stop"}, ignore}, // no session id
	} {
		if got := Apply(c.in); got != c.want {
			t.Errorf("%+v: got %+v want %+v", c.in, got, c.want)
		}
	}
	if got := Apply(Input{Event: "Stop", SessionID: "s"}).Status; got != state.Idle {
		t.Errorf("Stop status = %v", got)
	}
	if n := len(Events()); n != 10 {
		t.Errorf("registered events = %d, want 10", n)
	}
}
