package main

import (
	"testing"

	"kido/internal/tmux"
)

// The rules themselves are internal/reap's, and tested there. What is
// left here is the command: that it closes what a sweep names, and that
// it takes no arguments.
func TestReapClosesWhatTheSweepNames(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	// A finished subagent window - marked by kido spawn_subagent, its pane a
	// remain-on-exit corpse well past the linger - and a second window so
	// the session survives losing it.
	panes := []tmux.Pane{
		{PaneID: "%1", SessionID: "$0", WindowID: "@1"},
		{PaneID: "%2", SessionID: "$0", WindowID: "@2",
			Subagent: "parent=root-inst depth=1", Dead: true, DeadTime: 1},
	}
	killed := withCloseRunDeps(t, panes)

	if err := reapCmd(nil); err != nil {
		t.Fatal(err)
	}
	if len(*killed) != 1 || (*killed)[0] != "@2" {
		t.Errorf("killed = %v, want [@2]", *killed)
	}
}

// TestReapKillsTheRunsPaneWhenTheWindowIsShared is the command's half of
// the collection unit: what a sweep names is a pane, and the command
// kills that pane and hands the window back by unmarking it. Without the
// unmark the window goes on being drawn, nested and swept as a subagent's
// with nothing of kido's left in it.
func TestReapKillsTheRunsPaneWhenTheWindowIsShared(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	mark := "run=run-shared parent=root-inst depth=1"
	panes := []tmux.Pane{
		{PaneID: "%1", SessionID: "$0", WindowID: "@1"},
		{PaneID: "%2", SessionID: "$0", WindowID: "@2", Subagent: mark,
			SubagentPane: "run-shared", Dead: true, DeadTime: 1},
		{PaneID: "%3", SessionID: "$0", WindowID: "@2", Subagent: mark},
	}
	got := withCollectDeps(t, panes)

	if err := reapCmd(nil); err != nil {
		t.Fatal(err)
	}
	if len(got.panes) != 1 || got.panes[0] != "%2" {
		t.Errorf("killPane called for %v, want [%%2]: the run's own pane", got.panes)
	}
	if len(got.windows) != 0 {
		t.Errorf("killWindow called for %v, want the user's split left standing", got.windows)
	}
	if len(got.unmarked) != 1 || got.unmarked[0] != "@2" {
		t.Errorf("unmarked = %v, want [@2]", got.unmarked)
	}
}

func TestReapRejectsArguments(t *testing.T) {
	if err := reapCmd([]string{"unexpected"}); err == nil {
		t.Error("reapCmd with an argument = nil error, want a usage error")
	}
}
