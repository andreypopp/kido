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
	// AgentID is set on every event a subagent raises, and empty on the
	// ones the main loop raises. A subagent's tool calls report the parent
	// session id, so this is the only thing separating "the model is
	// working" from "a subagent kido is waiting on is working".
	AgentID string `json:"agent_id"`
	// BackgroundTasks lists shell/agent work still running when a turn ends.
	// Stop and SubagentStop fire even while these are in flight; kido treats
	// the session as still running rather than idle until they finish.
	BackgroundTasks []struct {
		Status string `json:"status"`
	} `json:"background_tasks"`
	// Background is not part of the payload: the caller sets it from the
	// session's last recorded state (state.Session.Background), which says
	// the main loop has already stopped and only background work is
	// holding the session at running. SubagentStop needs it to tell the
	// end of that background work from a subagent finishing mid-turn.
	Background bool `json:"-"`
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

// working is the effect of a tool call: the session is running. Whether it
// also clears a pending background wait depends on who made the call. A
// background subagent's tool calls arrive under the parent's session id and
// keep arriving for as long as the subagent runs, so treating them as the
// main loop waking up would clear the flag immediately and leave the
// session stuck at running once the subagent finished. Only a call from
// the main loop (no agent id) means the turn is going again.
func working(in Input) Effect {
	return Effect{Status: state.Running, Background: in.Background && in.AgentID != ""}
}

// startingTool is working for the PreToolUse that opens a tool call: the
// same running effect, plus the note that nothing more will be heard
// until the tool returns. PostToolUse goes through working and so leaves
// ToolPending false, closing the pair.
func startingTool(in Input) Effect {
	e := working(in)
	e.ToolPending = true
	return e
}

// blocked is the effect of something asking the user: the session is
// waiting. A pending background wait survives it, since a session whose
// main loop has stopped can only be blocked on behalf of the background
// work kido is waiting on, and that work is not over.
func blocked(in Input) Effect {
	return Effect{Status: state.Waiting, Background: in.Background}
}

// Effect is what an event means for the session.
type Effect struct {
	Status state.Status
	Ended  bool // a turn ended: the session is idle because work finished
	Remove bool // the session is gone
	Ignore bool // nothing to record
	// Background records that the main loop has stopped and the session is
	// running only because background work is still in flight. It is
	// written to the session (state.Session.Background) and comes back as
	// Input.Background on the next event.
	Background bool
	// ToolPending records that a tool call has started and not yet
	// returned, so the quiet that follows is the tool running rather than
	// the session wedging (state.Session.ToolPending). It needs no
	// carrying forward: every report writes a whole fresh Session, so any
	// later event leaves it false by not setting it.
	ToolPending bool
}

var (
	running    = Effect{Status: state.Running}
	waiting    = Effect{Status: state.Waiting}
	idle       = Effect{Status: state.Idle}
	ended      = Effect{Status: state.Idle, Ended: true}
	compacting = Effect{Status: state.Compacting}
	ignore     = Effect{Ignore: true}
	// backgrounded is a turn that ended with background work still going.
	backgrounded = Effect{Status: state.Running, Background: true}
)

// events maps each registered event to its effect. Some depend on payload
// fields, so the values are functions.
//
// The table is only as good as what Claude Code reports, and it reports
// nothing when a question is dismissed or a permission denied: a waiting
// session stays waiting here until the idle_prompt notification a minute
// later. kido catches that from the pane's screen instead; see
// internal/ui/screen.go.
var events = map[string]func(Input) Effect{
	"SessionStart":     func(Input) Effect { return idle },
	"SessionEnd":       func(Input) Effect { return Effect{Remove: true} },
	"UserPromptSubmit": func(Input) Effect { return running },
	"PostToolUse":      func(in Input) Effect { return working(in) },
	"Stop": func(in Input) Effect {
		if in.hasRunningBackgroundTask() {
			return backgrounded
		}
		return ended
	},
	// Nothing else moves a session off running once Stop parked it there
	// with background work outstanding: the main loop has stopped, so no
	// further Stop fires. SubagentStop is the only event that keeps
	// arriving, and its background_tasks - not the fact that it fired, as
	// it fires on every subagent turn - says when the wait is over.
	"SubagentStop": func(in Input) Effect {
		if in.Background && !in.hasRunningBackgroundTask() {
			return ended
		}
		return ignore
	},
	// Asking the user a question blocks like a permission prompt.
	"PreToolUse": func(in Input) Effect {
		if in.ToolName == "AskUserQuestion" {
			return blocked(in)
		}
		return startingTool(in)
	},
	"PermissionRequest": func(in Input) Effect { return blocked(in) },
	"Notification": func(in Input) Effect {
		switch in.NotificationType {
		case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
			return blocked(in)
		case "idle_prompt":
			// Fires when a turn ended without a Stop, e.g. after Esc - but
			// also a minute after every Stop, background work or not, and
			// it carries no background_tasks of its own. A session already
			// parked by Stop with work outstanding knows better.
			if in.Background {
				return ignore
			}
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

// allEvents is the full list of Claude Code hook events, per the Claude
// Code hooks reference. Most are not in the events table above (Apply
// treats them as unmapped); the shipped settings file registers only
// the events in the table, and one of these is registered by hand in a
// user's own settings.json to see its payload in the debug log.
var allEvents = []string{
	"SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "StopFailure",
	"PreToolUse", "PostToolUse", "PostToolUseFailure", "PostToolBatch",
	"PermissionRequest", "PermissionDenied", "SubagentStart", "SubagentStop",
	"TaskCreated", "TaskCompleted", "Notification", "MessageDisplay",
	"FileChanged", "CwdChanged", "ConfigChange", "DirectoryAdded",
	"WorktreeCreate", "WorktreeRemove", "PreCompact", "PostCompact",
	"PreModelSwitch", "PostModelSwitch", "Elicitation", "ElicitationResult",
	"InstructionsLoaded", "TeammateIdle", "Setup", "UserPromptExpansion",
}

// AllEvents lists every Claude Code hook event, sorted, including ones
// kido does not otherwise map to an effect.
func AllEvents() []string {
	names := append([]string(nil), allEvents...)
	sort.Strings(names)
	return names
}

// mapped reports whether event is in kido's effect table (Events()), as
// opposed to one of the other Claude Code events listed by AllEvents().
func mapped(event string) bool {
	_, ok := events[event]
	return ok
}

// Describe renders the effect of a hook event the way debug.log records
// it: "unmapped" for an event outside kido's table, else "remove",
// "ended", "ignore", or "status=<status>", with " background" appended
// when the session is only running because background work is.
func Describe(event string, e Effect) string {
	if !mapped(event) {
		return "unmapped"
	}
	switch {
	case e.Remove:
		return "remove"
	case e.Ended:
		return "ended"
	case e.Ignore:
		return "ignore"
	case e.Background:
		return "status=" + string(e.Status) + " background"
	default:
		return "status=" + string(e.Status)
	}
}

// Apply returns the effect of a hook payload.
func Apply(in Input) Effect {
	f, ok := events[in.Event]
	if !ok || in.SessionID == "" {
		return ignore
	}
	return f(in)
}
