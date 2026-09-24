package main

import (
	"testing"

	"kido/internal/tmux"
)

// withCloseWindowDeps points listPanes and killWindow at fakes so
// closeWindowCmd never talks to a real tmux server; killed records every
// window killWindow was actually asked to close.
func withCloseWindowDeps(t *testing.T, panes []tmux.Pane) *[]string {
	t.Helper()
	prevPanes, prevKill := listPanes, killWindow
	var killed []string
	listPanes = func() ([]tmux.Pane, error) { return panes, nil }
	killWindow = func(id string) error {
		killed = append(killed, id)
		return nil
	}
	t.Cleanup(func() {
		listPanes, killWindow = prevPanes, prevKill
	})
	return &killed
}

// TestCloseWindowRefusesFocused checks that a window which is some
// client's current window is left alone rather than killed.
func TestCloseWindowRefusesFocused(t *testing.T) {
	panes := []tmux.Pane{
		{PaneID: "%1", SessionID: "$0", WindowID: "@1", Active: true, SessionAttached: true},
		{PaneID: "%2", SessionID: "$0", WindowID: "@2", SessionAttached: true},
	}
	killed := withCloseWindowDeps(t, panes)

	if err := closeWindowCmd([]string{"@1"}); err != nil {
		t.Fatalf("closeWindowCmd on a focused window = %v, want no error (a skip, not a failure)", err)
	}
	if len(*killed) != 0 {
		t.Errorf("killWindow called for %v, want a focused window left untouched", *killed)
	}
}

// TestCloseWindowKillsUnfocused checks the ordinary case: a window that
// is not any client's current one, and whose panes are all dead, is
// closed.
func TestCloseWindowKillsUnfocused(t *testing.T) {
	panes := []tmux.Pane{
		{PaneID: "%1", SessionID: "$0", WindowID: "@1", Active: true, SessionAttached: true},
		{PaneID: "%2", SessionID: "$0", WindowID: "@2", Active: false, SessionAttached: true, Dead: true},
	}
	killed := withCloseWindowDeps(t, panes)

	if err := closeWindowCmd([]string{"@2"}); err != nil {
		t.Fatalf("closeWindowCmd = %v, want it to succeed", err)
	}
	if len(*killed) != 1 || (*killed)[0] != "@2" {
		t.Errorf("killed = %v, want [@2]", *killed)
	}
}

// TestCloseWindowRefusesALivePane pins the fix for the bug where a user
// split a subagent's finished window - the split's shell pane is still
// alive - and the linger helper closed the window anyway, taking the
// user's split with it. Only when every pane of the window is dead may
// close-window proceed.
func TestCloseWindowRefusesALivePane(t *testing.T) {
	panes := []tmux.Pane{
		{PaneID: "%1", SessionID: "$0", WindowID: "@1", Active: true, SessionAttached: true, Dead: true},
		{PaneID: "%2", SessionID: "$0", WindowID: "@2", Active: false, SessionAttached: true, Dead: true},
		{PaneID: "%3", SessionID: "$0", WindowID: "@2", Active: false, SessionAttached: true, Dead: false},
	}
	killed := withCloseWindowDeps(t, panes)

	if err := closeWindowCmd([]string{"@2"}); err != nil {
		t.Fatalf("closeWindowCmd on a window with a live pane = %v, want no error (a skip, not a failure)", err)
	}
	if len(*killed) != 0 {
		t.Errorf("killWindow called for %v, want a window with a live pane left untouched", *killed)
	}
}

// TestCloseWindowKillsWhenAllDead is the positive control for
// TestCloseWindowRefusesALivePane: once the split pane has also exited,
// the window is closed as before.
func TestCloseWindowKillsWhenAllDead(t *testing.T) {
	panes := []tmux.Pane{
		{PaneID: "%1", SessionID: "$0", WindowID: "@1", Active: true, SessionAttached: true, Dead: true},
		{PaneID: "%2", SessionID: "$0", WindowID: "@2", Active: false, SessionAttached: true, Dead: true},
		{PaneID: "%3", SessionID: "$0", WindowID: "@2", Active: false, SessionAttached: true, Dead: true},
	}
	killed := withCloseWindowDeps(t, panes)

	if err := closeWindowCmd([]string{"@2"}); err != nil {
		t.Fatalf("closeWindowCmd = %v, want it to succeed", err)
	}
	if len(*killed) != 1 || (*killed)[0] != "@2" {
		t.Errorf("killed = %v, want [@2]", *killed)
	}
}

// TestCloseWindowRefusesANonWindowID pins the hole the windowIDPattern
// check closes: kill-window resolves any tmux target, so a window named
// by anything but its id - a window name, an index, "session:window" -
// would slip past the focus check (which can only match a WindowID) and
// kill the very window the user was reading.
func TestCloseWindowRefusesANonWindowID(t *testing.T) {
	panes := []tmux.Pane{
		{PaneID: "%1", SessionID: "$0", WindowID: "@1", WindowName: "victim", Active: true, SessionAttached: true},
	}
	for _, target := range []string{"victim", "alpha:0", "0", "@1x", "-t"} {
		killed := withCloseWindowDeps(t, panes)
		if err := closeWindowCmd([]string{target}); err == nil {
			t.Errorf("closeWindowCmd(%q) = nil error, want a refusal: only a window id may be closed", target)
		}
		if len(*killed) != 0 {
			t.Errorf("closeWindowCmd(%q) killed %v", target, *killed)
		}
	}
}

// TestCloseWindowRefusesTheLastWindow pins the guard on the other way to
// lose what the user was reading: kill-window on a session's only window
// destroys the session, every other pane in it, and the client's view of
// all of it.
func TestCloseWindowRefusesTheLastWindow(t *testing.T) {
	// Not focused - nobody is attached - so only the last-window rule can
	// save it.
	panes := []tmux.Pane{{PaneID: "%1", SessionID: "$0", WindowID: "@1", Active: true}}
	killed := withCloseWindowDeps(t, panes)

	if err := closeWindowCmd([]string{"@1"}); err != nil {
		t.Fatalf("closeWindowCmd on a session's last window = %v, want no error (a skip, not a failure)", err)
	}
	if len(*killed) != 0 {
		t.Errorf("killWindow called for %v, want a session's only window left alone", *killed)
	}
}

func TestCloseWindowRequiresOneArg(t *testing.T) {
	withCloseWindowDeps(t, nil)
	for _, args := range [][]string{{}, {"@1", "@2"}, {""}} {
		if err := closeWindowCmd(args); err == nil {
			t.Errorf("closeWindowCmd(%v) = nil error, want a usage error", args)
		}
	}
}
