package tmux

import "testing"

// panes for the focus tests: two windows of an attached session, one of a
// session nobody is attached to.
var focusPanes = []Pane{
	{PaneID: "%1", SessionID: "$0", WindowID: "@1", Active: true, SessionAttached: true},
	{PaneID: "%2", SessionID: "$0", WindowID: "@2", Active: false, SessionAttached: true},
	{PaneID: "%3", SessionID: "$1", WindowID: "@3", Active: true, SessionAttached: false},
}

func TestWindowFocused(t *testing.T) {
	if !WindowFocused(focusPanes, "@1") {
		t.Error("@1 is the current window of an attached session, want focused")
	}
	if WindowFocused(focusPanes, "@2") {
		t.Error("@2 is not its session's current window, want not focused")
	}
	// @3 is its session's current window, but no client is attached to
	// that session: nobody is reading it.
	if WindowFocused(focusPanes, "@3") {
		t.Error("a detached session's current window must not count as focused")
	}
	if WindowFocused(focusPanes, "@nonexistent") {
		t.Error("a window absent from the pane list must never be reported focused")
	}
}

// TestLastWindow pins the guard that keeps close-window and the reaper
// from destroying a session: $1 has one window, so closing it would take
// the session with it.
func TestLastWindow(t *testing.T) {
	if LastWindow(focusPanes, "@1") {
		t.Error("@1 is one of $0's two windows, want it closable")
	}
	if !LastWindow(focusPanes, "@3") {
		t.Error("@3 is $1's only window, want it recognised as the last one")
	}
	if LastWindow(focusPanes, "@nonexistent") {
		t.Error("a window absent from the pane list belongs to no session, want false")
	}
}

// allDeadPanes: @1 has one dead and one live pane (a split still running
// something), @2 is entirely dead.
var allDeadPanes = []Pane{
	{PaneID: "%1", WindowID: "@1", Dead: true},
	{PaneID: "%2", WindowID: "@1", Dead: false},
	{PaneID: "%3", WindowID: "@2", Dead: true},
	{PaneID: "%4", WindowID: "@2", Dead: true},
}

// TestWindowAllDead pins the rule close-window and the sweep must agree
// on: a window is finished only once every pane of it is.
func TestWindowAllDead(t *testing.T) {
	if WindowAllDead(allDeadPanes, "@1") {
		t.Error("@1 has a live pane, want not all dead")
	}
	if !WindowAllDead(allDeadPanes, "@2") {
		t.Error("@2's panes are all dead, want all dead")
	}
	if WindowAllDead(allDeadPanes, "@nonexistent") {
		t.Error("a window absent from the pane list has no dead panes to speak of, want false")
	}
}
