package ui

import (
	"testing"
	"time"

	"kido/internal/tmux"
)

// TestShellOutcome covers the shell counterpart of done: the last command's
// exit status marks the row, green for 0 and red otherwise, until the pane
// is visited.
func TestShellOutcome(t *testing.T) {
	// started stands in for panes never visited; visited is later, so an
	// outcome that predates it has been looked at.
	started := time.Unix(1700000000, 0)
	endedAt := int64(1700000100)
	visited := time.Unix(1700000200, 0)

	// integrated is a shell at its prompt with OSC 133 on: a prompt has
	// been marked and nothing is running.
	integrated := func(p tmux.Pane) tmux.Pane {
		p.PaneID = "%1"
		p.LastPromptTime = endedAt
		if p.CommandStartTime == 0 {
			// A command has actually run here: shellOutcome insists on
			// the 133;C that sets this, so a pane that has only ever
			// drawn its first prompt reports no outcome.
			p.CommandStartTime = endedAt - 1
		}
		return p
	}

	for _, tc := range []struct {
		name       string
		pane       tmux.Pane
		seen       map[string]time.Time
		wantStatus int
		wantOK     bool
	}{{
		// No OSC 133 at all: kido knows nothing about this pane.
		name: "no integration",
		pane: tmux.Pane{PaneID: "%1", CommandStatus: 1, CommandStatusOK: true,
			CommandEndTime: endedAt},
	}, {
		// A command is running now: no outcome, and the status on record
		// belongs to the previous command.
		name: "running",
		pane: integrated(tmux.Pane{CommandRunning: true, CommandStartTime: endedAt + 1,
			CommandStatus: 1, CommandStatusOK: true, CommandEndTime: endedAt}),
	}, {
		name: "clean exit, not yet visited",
		pane: integrated(tmux.Pane{CommandStatus: 0, CommandStatusOK: true,
			CommandEndTime: endedAt}),
		wantStatus: 0,
		wantOK:     true,
	}, {
		name: "nonzero exit, not yet visited",
		pane: integrated(tmux.Pane{CommandStatus: 1, CommandStatusOK: true,
			CommandEndTime: endedAt}),
		wantStatus: 1,
		wantOK:     true,
	}, {
		name: "nonzero exit, pane visited since",
		pane: integrated(tmux.Pane{CommandStatus: 1, CommandStatusOK: true,
			CommandEndTime: endedAt}),
		seen: map[string]time.Time{"%1": visited},
	}, {
		// tmux prints pane_command_status empty when it has none, which
		// parses to a zero CommandStatus: the flag is what keeps that from
		// reading as a clean exit, and neither is an outcome.
		name: "no status on record",
		pane: integrated(tmux.Pane{CommandStatus: 0, CommandStatusOK: false,
			CommandEndTime: endedAt}),
	}, {
		// The first prompt of a fresh shell emits 133;D with the rc's exit
		// status and no 133;C before it, so there is a status and an end
		// time but no start time: nothing has run, and the row must stay
		// blank rather than wearing a checkmark it did not earn.
		name: "no command has run",
		pane: tmux.Pane{PaneID: "%1", LastPromptTime: endedAt,
			CommandStatus: 0, CommandStatusOK: true, CommandEndTime: endedAt},
	}, {
		// A status on record with no end time is not datable against the
		// last visit, so it cannot mark the row.
		name: "no end time",
		pane: integrated(tmux.Pane{CommandStatus: 1, CommandStatusOK: true}),
	}} {
		t.Run(tc.name, func(t *testing.T) {
			seen := tc.seen
			if seen == nil {
				seen = map[string]time.Time{}
			}
			m := &model{started: started, seen: seen}
			status, ok := m.shellOutcome(tc.pane)
			if ok != tc.wantOK || (ok && status != tc.wantStatus) {
				t.Errorf("shellOutcome() = (%v, %v), want (%v, %v)", status, ok, tc.wantStatus, tc.wantOK)
			}
		})
	}
}
