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
	for _, c := range []struct {
		in   Input
		want Effect
	}{
		{Input{Event: "SessionStart", SessionID: "s"}, idle},
		{Input{Event: "Stop", SessionID: "s"}, ended},
		{Input{Event: "Stop", SessionID: "s", BackgroundTasks: tasks("running")}, backgrounded},
		{Input{Event: "Stop", SessionID: "s", BackgroundTasks: tasks("completed")}, ended},
		{Input{Event: "Stop", SessionID: "s", BackgroundTasks: tasks()}, ended},
		// A turn parked at running by background work ends when the last
		// of it finishes, and only then: SubagentStop fires on every
		// subagent turn, and says nothing about a session that was not
		// waiting on one.
		{Input{Event: "SubagentStop", SessionID: "s", Background: true}, ended},
		{Input{Event: "SubagentStop", SessionID: "s", Background: true, BackgroundTasks: tasks("completed")}, ended},
		{Input{Event: "SubagentStop", SessionID: "s", Background: true, BackgroundTasks: tasks("running")}, ignore},
		{Input{Event: "SubagentStop", SessionID: "s", BackgroundTasks: tasks()}, ignore},
		{Input{Event: "SubagentStop", SessionID: "s", BackgroundTasks: tasks("running")}, ignore},
		{Input{Event: "PreToolUse", SessionID: "s", ToolName: "Bash"}, running},
		// The main loop working again ends the wait; a background
		// subagent's own tool calls, which arrive under the same session
		// id, do not.
		{Input{Event: "PreToolUse", SessionID: "s", ToolName: "Bash", Background: true}, running},
		{Input{Event: "PostToolUse", SessionID: "s", Background: true}, running},
		{Input{Event: "UserPromptSubmit", SessionID: "s", Background: true}, running},
		{Input{Event: "PreToolUse", SessionID: "s", ToolName: "Bash", AgentID: "a", Background: true}, backgrounded},
		{Input{Event: "PostToolUse", SessionID: "s", AgentID: "a", Background: true}, backgrounded},
		{Input{Event: "PreToolUse", SessionID: "s", ToolName: "Bash", AgentID: "a"}, running},
		{Input{Event: "PreToolUse", SessionID: "s", ToolName: "AskUserQuestion"}, waiting},
		{Input{Event: "Notification", SessionID: "s", NotificationType: "permission_prompt"}, waiting},
		{Input{Event: "Notification", SessionID: "s", NotificationType: "idle_prompt"}, ended},
		// idle_prompt fires a minute after every turn ends, knowing nothing
		// of background work: it must not end a turn Stop parked, nor must
		// a prompt raised on the background work's behalf clear the wait.
		{Input{Event: "Notification", SessionID: "s", NotificationType: "idle_prompt", Background: true}, ignore},
		{Input{Event: "Notification", SessionID: "s", NotificationType: "permission_prompt", Background: true}, Effect{Status: state.Waiting, Background: true}},
		{Input{Event: "PermissionRequest", SessionID: "s", Background: true}, Effect{Status: state.Waiting, Background: true}},
		{Input{Event: "PreToolUse", SessionID: "s", ToolName: "AskUserQuestion", Background: true}, Effect{Status: state.Waiting, Background: true}},
		{Input{Event: "PermissionRequest", SessionID: "s"}, waiting},
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
	if n := len(Events()); n != 11 {
		t.Errorf("registered events = %d, want 11", n)
	}
}

func TestAllEvents(t *testing.T) {
	all := AllEvents()
	if n := len(all); n != 33 {
		t.Errorf("len(AllEvents()) = %d, want 33", n)
	}
	seen := map[string]bool{}
	prev := ""
	for _, e := range all {
		if seen[e] {
			t.Errorf("duplicate event %q", e)
		}
		seen[e] = true
		if e < prev {
			t.Errorf("AllEvents() not sorted: %q before %q", prev, e)
		}
		prev = e
	}
	for _, e := range Events() {
		if !seen[e] {
			t.Errorf("Events() event %q missing from AllEvents()", e)
		}
		if !mapped(e) {
			t.Errorf("mapped(%q) = false, want true", e)
		}
	}
	if mapped("FileChanged") {
		t.Errorf("mapped(FileChanged) = true, want false")
	}
	if mapped("NoSuchEvent") {
		t.Errorf("mapped(NoSuchEvent) = true, want false")
	}
}

func TestDescribe(t *testing.T) {
	for _, c := range []struct {
		event string
		e     Effect
		want  string
	}{
		{"FileChanged", Effect{}, "unmapped"},
		{"SessionEnd", Effect{Remove: true}, "remove"},
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
