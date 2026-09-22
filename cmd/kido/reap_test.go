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
	// A finished subagent window - marked by kido spawn, its pane a
	// remain-on-exit corpse well past the linger - and a second window so
	// the session survives losing it.
	panes := []tmux.Pane{
		{PaneID: "%1", SessionID: "$0", WindowID: "@1"},
		{PaneID: "%2", SessionID: "$0", WindowID: "@2",
			Subagent: "parent=root-inst depth=1", Dead: true, DeadTime: 1},
	}
	killed := withCloseWindowDeps(t, panes)

	if err := reapCmd(nil); err != nil {
		t.Fatal(err)
	}
	if len(*killed) != 1 || (*killed)[0] != "@2" {
		t.Errorf("killed = %v, want [@2]", *killed)
	}
}

func TestReapRejectsArguments(t *testing.T) {
	if err := reapCmd([]string{"unexpected"}); err == nil {
		t.Error("reapCmd with an argument = nil error, want a usage error")
	}
}
