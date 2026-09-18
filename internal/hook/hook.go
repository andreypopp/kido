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
	// BackgroundTasks lists shell/agent work still running when a turn ends.
	// Stop and SubagentStop fire even while these are in flight; kido treats
	// the session as still running rather than idle until they finish.
	BackgroundTasks []struct {
		Status string `json:"status"`
	} `json:"background_tasks"`
}

// hasRunningBackgroundTask reports whether any background task is still
// running.
func (in Input) hasRunningBackgroundTask() bool {
	for _, t := range in.BackgroundTasks {
		if t.Status == "running" {
			return true
		}
	}
	return false
}

// Effect is what an event means for the session.
type Effect struct {
	Status state.Status
	Ended  bool // a turn ended: the session is idle because work finished
	Remove bool // the session is gone
	Ignore bool // nothing to record
}

var (
	running    = Effect{Status: state.Running}
	waiting    = Effect{Status: state.Waiting}
	idle       = Effect{Status: state.Idle}
	ended      = Effect{Status: state.Idle, Ended: true}
	compacting = Effect{Status: state.Compacting}
	ignore     = Effect{Ignore: true}
)

// events maps each registered event to its effect. Some depend on payload
// fields, so the values are functions.
var events = map[string]func(Input) Effect{
	"SessionStart":     func(Input) Effect { return idle },
	"SessionEnd":       func(Input) Effect { return Effect{Remove: true} },
	"UserPromptSubmit": func(Input) Effect { return running },
	"PostToolUse":      func(Input) Effect { return running },
	"Stop": func(in Input) Effect {
		if in.hasRunningBackgroundTask() {
			return running
		}
		return ended
	},
	// Asking the user a question blocks like a permission prompt.
	"PreToolUse": func(in Input) Effect {
		if in.ToolName == "AskUserQuestion" {
			return waiting
		}
		return running
	},
	"PermissionRequest": func(Input) Effect { return waiting },
	"Notification": func(in Input) Effect {
		switch in.NotificationType {
		case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
			return waiting
		case "idle_prompt":
			// Fires when a turn ended without a Stop, e.g. after Esc.
			return ended
		}
		return ignore
	},
	"PreCompact": func(Input) Effect { return compacting },
	// An automatic compaction happens mid-turn and work resumes; a manual
	// /compact leaves the session waiting for input.
	"PostCompact": func(in Input) Effect {
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

// Apply returns the effect of a hook payload.
func Apply(in Input) Effect {
	f, ok := events[in.Event]
	if !ok || in.SessionID == "" {
		return ignore
	}
	return f(in)
}
