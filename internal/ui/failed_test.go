package ui

import (
	"testing"
	"time"

	"kido/internal/tmux"
)

// TestFailed covers the shell counterpart of done: a command that exited
// nonzero marks the row until the pane is visited.
func TestFailed(t *testing.T) {
	// started stands in for panes never visited; visited is later, so a
	// failure that predates it has been looked at.
	started := time.Unix(1700000000, 0)
	failedAt := int64(1700000100)
	visited := time.Unix(1700000200, 0)

	// integrated is a shell at its prompt with OSC 133 on: a prompt has
	// been marked and nothing is running.
	integrated := func(p tmux.Pane) tmux.Pane {
		p.PaneID = "%1"
		p.LastPromptTime = failedAt
		return p
	}

	for _, tc := range []struct {
		name string
		pane tmux.Pane
		seen map[string]time.Time
		want bool
	}{{
		// No OSC 133 at all: kido knows nothing about this pane.
		name: "no integration",
		pane: tmux.Pane{PaneID: "%1", CommandStatus: 1, CommandStatusOK: true,
			CommandEndTime: failedAt},
	}, {
		// A command is running now: the green indicator wins, and the
		// status on record belongs to the previous command.
		name: "running",
		pane: integrated(tmux.Pane{CommandRunning: true, CommandStartTime: failedAt + 1,
			CommandStatus: 1, CommandStatusOK: true, CommandEndTime: failedAt}),
	}, {
		name: "clean exit",
		pane: integrated(tmux.Pane{CommandStatus: 0, CommandStatusOK: true,
			CommandEndTime: failedAt}),
	}, {
		name: "nonzero exit, not yet visited",
		pane: integrated(tmux.Pane{CommandStatus: 1, CommandStatusOK: true,
			CommandEndTime: failedAt}),
		want: true,
	}, {
		name: "nonzero exit, pane visited since",
		pane: integrated(tmux.Pane{CommandStatus: 1, CommandStatusOK: true,
			CommandEndTime: failedAt}),
		seen: map[string]time.Time{"%1": visited},
	}, {
		// tmux prints pane_command_status empty when it has none, which
		// parses to a zero CommandStatus: the flag is what keeps that
		// from reading as a clean exit, and neither is a failure.
		name: "nonzero exit with an empty status field",
		pane: integrated(tmux.Pane{CommandStatus: 0, CommandStatusOK: false,
			CommandEndTime: failedAt}),
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
			if got := m.failed(tc.pane); got != tc.want {
				t.Errorf("failed() = %v, want %v", got, tc.want)
			}
		})
	}
}
