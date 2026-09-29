// Package hook maps Claude Code hook events to sidebar statuses. It is the
// single source for which events kido registers and what they mean.
package hook

import (
	"sort"

	"kido/internal/state"
)

// Input is the part of a Claude Code hook payload kido reads.
type Input struct {
	Event            string `json:"hook_event_name"`
	SessionID        string `json:"session_id"`
	NotificationType string `json:"notification_type"`
	Trigger          string `json:"trigger"`   // PreCompact/PostCompact: "auto" or "manual"
	ToolName         string `json:"tool_name"` // PreToolUse/PostToolUse
	// AgentID is set on every event a subagent raises, empty on the main
	// loop's: a subagent's tool calls arrive under the parent session id,
	// so this is the only way to tell the two apart.
	AgentID string `json:"agent_id"`
	// BackgroundTasks lists shell/agent work still running when a turn ends.
	// Stop and SubagentStop fire even while these are in flight; kido treats
	// the session as still running rather than idle until they finish.
	BackgroundTasks []struct {
		Status string `json:"status"`
	} `json:"background_tasks"`
}

func (in Input) hasRunningBackgroundTask() bool {
	for _, t := range in.BackgroundTasks {
		if t.Status == "running" {
			return true
		}
	}
	return false
}

// working clears a pending background wait only for a call with no
// agent id: a background subagent's tool calls keep arriving under the
// parent's session id for as long as it runs, and treating those as the
// main loop waking would clear the flag before the subagent finished.
func working(in Input, parked bool) Effect {
	return Report{Status: state.Running, Background: parked && in.AgentID != ""}
}

// startingTool is working plus ToolPending, for the PreToolUse that
// opens a tool call; PostToolUse goes through working and leaves
// ToolPending false, closing the pair.
func startingTool(in Input, parked bool) Effect {
	e := working(in, parked).(Report)
	e.ToolPending = true
	return e
}

func blocked(parked bool) Effect {
	return Report{Status: state.Waiting, Background: parked}
}

// Effect is what an event means for the session: ignore it, remove the
// record, or write a whole fresh report.
type Effect interface{ effect() }

// Ignore means nothing to record.
type Ignore struct{}

// Remove means the session is gone.
type Remove struct{}

// Report is a whole fresh status report.
type Report struct {
	Status      state.Status
	Ended       bool // a turn ended: idle because work finished; only with Idle
	Background  bool // main loop stopped, running only because background work is in flight
	ToolPending bool // a tool call started and has not yet returned
}

func (Ignore) effect() {}
func (Remove) effect() {}
func (Report) effect() {}

var (
	running      = Report{Status: state.Running}
	waiting      = Report{Status: state.Waiting}
	idle         = Report{Status: state.Idle}
	ended        = Report{Status: state.Idle, Ended: true}
	compacting   = Report{Status: state.Compacting}
	ignore       = Ignore{}
	backgrounded = Report{Status: state.Running, Background: true}
)

// events maps each registered event to its effect. Some depend on payload
// fields, so the values are functions.
//
// Claude Code reports nothing when a question is dismissed or a
// permission denied: a waiting session stays waiting here until the
// idle_prompt notification a minute later. kido catches that from the
// pane's screen instead; see internal/ui/screen.go.
var events = map[string]func(Input, bool) Effect{
	"SessionStart":     func(Input, bool) Effect { return idle },
	"SessionEnd":       func(Input, bool) Effect { return Remove{} },
	"UserPromptSubmit": func(Input, bool) Effect { return running },
	"PostToolUse":      func(in Input, parked bool) Effect { return working(in, parked) },
	"Stop": func(in Input, parked bool) Effect {
		if in.hasRunningBackgroundTask() {
			return backgrounded
		}
		return ended
	},
	// SubagentStop fires on every subagent turn regardless of outcome; only
	// its background_tasks says when a parked wait is over.
	"SubagentStop": func(in Input, parked bool) Effect {
		if parked && !in.hasRunningBackgroundTask() {
			return ended
		}
		return ignore
	},
	"PreToolUse": func(in Input, parked bool) Effect {
		if in.ToolName == "AskUserQuestion" {
			return blocked(parked)
		}
		return startingTool(in, parked)
	},
	"PermissionRequest": func(in Input, parked bool) Effect { return blocked(parked) },
	"Notification": func(in Input, parked bool) Effect {
		switch in.NotificationType {
		case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
			return blocked(parked)
		case "idle_prompt":
			// Fires ~60s after every Stop, background work or not, with no
			// background_tasks of its own; a session already parked knows better.
			if parked {
				return ignore
			}
			return ended
		default:
			return ignore
		}
	},
	"PreCompact": func(Input, bool) Effect { return compacting },
	// Automatic compaction happens mid-turn and work resumes; manual
	// /compact leaves the session waiting for input.
	"PostCompact": func(in Input, parked bool) Effect {
		if in.Trigger == "manual" {
			return ended
		}
		return running
	},
}

// Events lists the hook events kido registers, sorted.
func Events() []string {
	names := make([]string, 0, len(events))
	for name := range events {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

func mapped(event string) bool {
	_, ok := events[event]
	return ok
}

// Describe renders the effect of a hook event the way debug.log records
// it: "unmapped", "remove", "ended", "ignore", or "status=<status>",
// with " background" appended when running only because background work is.
func Describe(event string, e Effect) string {
	if !mapped(event) {
		return "unmapped"
	}
	switch e := e.(type) {
	case Remove:
		return "remove"
	case Ignore:
		return "ignore"
	case Report:
		switch {
		case e.Ended:
			return "ended"
		case e.Background:
			return "status=" + string(e.Status) + " background"
		default:
			return "status=" + string(e.Status)
		}
	}
	panic("unreachable")
}

// Apply returns the effect of a hook payload. parked is the session's
// prior state.Session.Background: whether the main loop has already
// stopped and only background work is holding the session at running.
func Apply(in Input, parked bool) Effect {
	f, ok := events[in.Event]
	if !ok || in.SessionID == "" {
		return ignore
	}
	return f(in, parked)
}
