package ui

import (
	"testing"
	"time"

	"kido/internal/tmux"
)

// TestShellOutcome covers the shell counterpart of done: the last command's
// exit status marks the row, green for 0 and red otherwise, until the pane
// is visited. It pins two tmux/zsh quirks: `C` clears cmd_status, and a
// first prompt emits `D` with no `C` before it, which must mark nothing.
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
		name string
		pane tmux.Pane
		seen map[string]time.Time
		want *tmux.Exit
	}{{
		// No OSC 133 at all: kido knows nothing about this pane.
		name: "no integration",
		pane: tmux.Pane{PaneID: "%1", LastExit: &tmux.Exit{Code: 1, At: endedAt}},
	}, {
		// A command is running now: no outcome, and the status on record
		// belongs to the previous command.
		name: "running",
		pane: integrated(tmux.Pane{CommandRunning: true, CommandStartTime: endedAt + 1,
			LastExit: &tmux.Exit{Code: 1, At: endedAt}}),
	}, {
		name: "clean exit, not yet visited",
		pane: integrated(tmux.Pane{LastExit: &tmux.Exit{Code: 0, At: endedAt}}),
		want: &tmux.Exit{Code: 0, At: endedAt},
	}, {
		name: "nonzero exit, not yet visited",
		pane: integrated(tmux.Pane{LastExit: &tmux.Exit{Code: 1, At: endedAt}}),
		want: &tmux.Exit{Code: 1, At: endedAt},
	}, {
		name: "nonzero exit, pane visited since",
		pane: integrated(tmux.Pane{LastExit: &tmux.Exit{Code: 1, At: endedAt}}),
		seen: map[string]time.Time{"%1": visited},
	}, {
		// tmux prints pane_command_status empty when it has none, which
		// leaves LastExit nil: that is what keeps a pane with nothing on
		// record from reading as a clean exit.
		name: "no status on record",
		pane: integrated(tmux.Pane{}),
	}, {
		// The first prompt of a fresh shell emits 133;D with the rc's exit
		// status and no 133;C before it, so there is a status and an end
		// time but no start time: nothing has run, and the row must stay
		// blank rather than wearing a checkmark it did not earn.
		name: "no command has run",
		pane: tmux.Pane{PaneID: "%1", LastPromptTime: endedAt,
			LastExit: &tmux.Exit{Code: 0, At: endedAt}},
	}, {
		// A status on record with no end time is not datable against the
		// last visit, so it cannot mark the row.
		name: "no end time",
		pane: integrated(tmux.Pane{LastExit: &tmux.Exit{Code: 1}}),
	}} {
		t.Run(tc.name, func(t *testing.T) {
			seen := tc.seen
			if seen == nil {
				seen = map[string]time.Time{}
			}
			m := &model{started: started, seen: seen}
			got := m.shellOutcome(tc.pane)
			if (got == nil) != (tc.want == nil) || (got != nil && *got != *tc.want) {
				t.Errorf("shellOutcome() = %+v, want %+v", got, tc.want)
			}
		})
	}
}
