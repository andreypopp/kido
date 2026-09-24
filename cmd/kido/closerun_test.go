package main

import (
	"testing"

	"kido/internal/tmux"
)

// withCloseRunDeps points listPanes and killWindow at fakes so
// closeRunCmd never talks to a real tmux server; killed records every
// window killWindow was actually asked to close.
func withCloseRunDeps(t *testing.T, panes []tmux.Pane) *[]string {
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

// collected is everything the linger helper did to a tmux server in one
// call: the windows it closed, the panes it killed and the windows it
// unmarked.
type collected struct {
	windows  []string
	panes    []string
	unmarked []string
}

// withCollectDeps is withCloseRunDeps for the tests whose subject is
// the pane: the helper's unit of collection is a run's pane, so a test
// that watched only killWindow could not tell "nothing was closed" from
// "the run's pane was".
func withCollectDeps(t *testing.T, panes []tmux.Pane) *collected {
	t.Helper()
	prevPanes, prevKillWindow, prevKillPane, prevUnmark := listPanes, killWindow, killPane, unmarkSubagent
	var got collected
	listPanes = func() ([]tmux.Pane, error) { return panes, nil }
	killWindow = func(id string) error {
		got.windows = append(got.windows, id)
		return nil
	}
	killPane = func(id string) error {
		got.panes = append(got.panes, id)
		return nil
	}
	unmarkSubagent = func(id string) error {
		got.unmarked = append(got.unmarked, id)
		return nil
	}
	t.Cleanup(func() {
		listPanes, killWindow, killPane, unmarkSubagent = prevPanes, prevKillWindow, prevKillPane, prevUnmark
	})
	return &got
}

// runPane is the one pane a run runs in: the pane-scoped
// @kido_subagent_pane option, which no pane the user splits off later
// carries.
func runPane(p tmux.Pane, runID string) tmux.Pane {
	p.Subagent = "run=" + runID + " parent=root-inst depth=1"
	p.SubagentPane = runID
	return p
}

// splitPane is a pane the user added to a run's window: it reads the
// window mark through tmux's own option fallback and nothing else.
func splitPane(p tmux.Pane, runID string) tmux.Pane {
	p.Subagent = "run=" + runID + " parent=root-inst depth=1"
	return p
}

// TestCloseRunKillsTheRunsPaneAndLeavesTheSplit is the incident this
// helper's unit changed for: the user split a shell into a subagent's
// window and the run finished, so what the linger is finished with is
// the run's dead pane. Closing the window would take the user's shell
// with it; leaving the window alone left a corpse beside them.
func TestCloseRunKillsTheRunsPaneAndLeavesTheSplit(t *testing.T) {
	panes := []tmux.Pane{
		{PaneID: "%1", SessionID: "$0", WindowID: "@1", Active: true, SessionAttached: true},
		dead(runPane(tmux.Pane{PaneID: "%2", SessionID: "$0", WindowID: "@2"}, "run-x")),
		splitPane(tmux.Pane{PaneID: "%3", SessionID: "$0", WindowID: "@2"}, "run-x"),
	}
	got := withCollectDeps(t, panes)

	if err := closeRunCmd([]string{"@2"}); err != nil {
		t.Fatalf("closeRunCmd = %v, want it to collect the run's pane", err)
	}
	if len(got.panes) != 1 || got.panes[0] != "%2" {
		t.Errorf("killPane called for %v, want [%%2]: the run's own dead pane", got.panes)
	}
	if len(got.windows) != 0 {
		t.Errorf("killWindow called for %v, want the window left standing for the user's split", got.windows)
	}
	if len(got.unmarked) != 1 || got.unmarked[0] != "@2" {
		t.Errorf("unmarked = %v, want [@2]: a window whose run is collected is an ordinary window", got.unmarked)
	}
}

// TestCloseRunClosesTheWindowWhenTheRunIsAllOfIt is the negative control
// for the test above and the ordinary case: nothing beside the run's
// pane, so the window goes exactly as it always did.
func TestCloseRunClosesTheWindowWhenTheRunIsAllOfIt(t *testing.T) {
	panes := []tmux.Pane{
		{PaneID: "%1", SessionID: "$0", WindowID: "@1", Active: true, SessionAttached: true},
		dead(runPane(tmux.Pane{PaneID: "%2", SessionID: "$0", WindowID: "@2"}, "run-x")),
	}
	got := withCollectDeps(t, panes)

	if err := closeRunCmd([]string{"@2"}); err != nil {
		t.Fatalf("closeRunCmd = %v, want it to close the window", err)
	}
	if len(got.windows) != 1 || got.windows[0] != "@2" {
		t.Errorf("killWindow called for %v, want [@2]", got.windows)
	}
	if len(got.panes) != 0 {
		t.Errorf("killPane called for %v, want the window closed rather than its last pane killed", got.panes)
	}
}

// TestCloseRunRefusesALiveRunsPane: a run still going is not collected
// because the user's split beside it exited.
func TestCloseRunRefusesALiveRunsPane(t *testing.T) {
	panes := []tmux.Pane{
		{PaneID: "%1", SessionID: "$0", WindowID: "@1", Active: true, SessionAttached: true},
		runPane(tmux.Pane{PaneID: "%2", SessionID: "$0", WindowID: "@2"}, "run-x"),
		dead(splitPane(tmux.Pane{PaneID: "%3", SessionID: "$0", WindowID: "@2"}, "run-x")),
	}
	got := withCollectDeps(t, panes)

	if err := closeRunCmd([]string{"@2"}); err != nil {
		t.Fatalf("closeRunCmd on a live run = %v, want no error (a skip, not a failure)", err)
	}
	if len(got.panes) != 0 || len(got.windows) != 0 {
		t.Errorf("killed panes %v and windows %v, want a live run left alone", got.panes, got.windows)
	}
}

// TestCloseRunRefusesAFocusedWindowWithASplit holds the focus rule to
// one rule for both units: the user is in the window reading what the
// run left, and the pane is theirs to keep until they leave.
func TestCloseRunRefusesAFocusedWindowWithASplit(t *testing.T) {
	panes := []tmux.Pane{
		{PaneID: "%1", SessionID: "$0", WindowID: "@1", SessionAttached: true},
		dead(runPane(tmux.Pane{PaneID: "%2", SessionID: "$0", WindowID: "@2"}, "run-x")),
		splitPane(tmux.Pane{PaneID: "%3", SessionID: "$0", WindowID: "@2", Active: true, SessionAttached: true}, "run-x"),
	}
	got := withCollectDeps(t, panes)

	if err := closeRunCmd([]string{"@2"}); err != nil {
		t.Fatalf("closeRunCmd on a focused window = %v, want no error (a skip, not a failure)", err)
	}
	if len(got.panes) != 0 || len(got.windows) != 0 {
		t.Errorf("killed panes %v and windows %v, want the window the user is reading left alone", got.panes, got.windows)
	}
}

// TestCloseRunKillsARunsPaneInASessionsLastWindow: the last-window
// refusal is about destroying a session, and a window with another pane
// in it loses no session when the run's pane goes.
func TestCloseRunKillsARunsPaneInASessionsLastWindow(t *testing.T) {
	panes := []tmux.Pane{
		dead(runPane(tmux.Pane{PaneID: "%1", SessionID: "$0", WindowID: "@1"}, "run-x")),
		splitPane(tmux.Pane{PaneID: "%2", SessionID: "$0", WindowID: "@1"}, "run-x"),
	}
	got := withCollectDeps(t, panes)

	if err := closeRunCmd([]string{"@1"}); err != nil {
		t.Fatalf("closeRunCmd = %v, want it to collect the run's pane", err)
	}
	if len(got.panes) != 1 || got.panes[0] != "%1" || len(got.windows) != 0 {
		t.Errorf("killed panes %v and windows %v, want the run's pane alone: no session is lost by it", got.panes, got.windows)
	}
}

// dead is a pane as remain-on-exit leaves it.
func dead(p tmux.Pane) tmux.Pane {
	p.Dead, p.DeadTime = true, 1700000000
	return p
}

// TestCloseRunRefusesFocused checks that a window which is some
// client's current window is left alone rather than killed.
func TestCloseRunRefusesFocused(t *testing.T) {
	panes := []tmux.Pane{
		{PaneID: "%1", SessionID: "$0", WindowID: "@1", Active: true, SessionAttached: true},
		{PaneID: "%2", SessionID: "$0", WindowID: "@2", SessionAttached: true},
	}
	killed := withCloseRunDeps(t, panes)

	if err := closeRunCmd([]string{"@1"}); err != nil {
		t.Fatalf("closeRunCmd on a focused window = %v, want no error (a skip, not a failure)", err)
	}
	if len(*killed) != 0 {
		t.Errorf("killWindow called for %v, want a focused window left untouched", *killed)
	}
}

// TestCloseRunKillsUnfocused checks the ordinary case: a window that
// is not any client's current one, and whose panes are all dead, is
// closed.
func TestCloseRunKillsUnfocused(t *testing.T) {
	panes := []tmux.Pane{
		{PaneID: "%1", SessionID: "$0", WindowID: "@1", Active: true, SessionAttached: true},
		{PaneID: "%2", SessionID: "$0", WindowID: "@2", Active: false, SessionAttached: true, Dead: true},
	}
	killed := withCloseRunDeps(t, panes)

	if err := closeRunCmd([]string{"@2"}); err != nil {
		t.Fatalf("closeRunCmd = %v, want it to succeed", err)
	}
	if len(*killed) != 1 || (*killed)[0] != "@2" {
		t.Errorf("killed = %v, want [@2]", *killed)
	}
}

// TestCloseRunRefusesALivePaneOnAnOldMark is the fallback for a window
// marked by a kido from before @kido_subagent_pane existed: nothing there
// tells the run's own pane from one the user split off later, so the
// window stays the unit and is left alone until every pane of it is
// dead. It began as the fix for the bug where the helper closed such a
// window anyway, taking the user's live split with it.
func TestCloseRunRefusesALivePaneOnAnOldMark(t *testing.T) {
	panes := []tmux.Pane{
		{PaneID: "%1", SessionID: "$0", WindowID: "@1", Active: true, SessionAttached: true, Dead: true},
		{PaneID: "%2", SessionID: "$0", WindowID: "@2", Active: false, SessionAttached: true, Dead: true},
		{PaneID: "%3", SessionID: "$0", WindowID: "@2", Active: false, SessionAttached: true, Dead: false},
	}
	killed := withCloseRunDeps(t, panes)

	if err := closeRunCmd([]string{"@2"}); err != nil {
		t.Fatalf("closeRunCmd on a window with a live pane = %v, want no error (a skip, not a failure)", err)
	}
	if len(*killed) != 0 {
		t.Errorf("killWindow called for %v, want a window with a live pane left untouched", *killed)
	}
}

// TestCloseRunKillsWhenAllDead is the positive control for
// TestCloseRunRefusesALivePaneOnAnOldMark: once the split pane has also
// exited, the window is closed as before.
func TestCloseRunKillsWhenAllDead(t *testing.T) {
	panes := []tmux.Pane{
		{PaneID: "%1", SessionID: "$0", WindowID: "@1", Active: true, SessionAttached: true, Dead: true},
		{PaneID: "%2", SessionID: "$0", WindowID: "@2", Active: false, SessionAttached: true, Dead: true},
		{PaneID: "%3", SessionID: "$0", WindowID: "@2", Active: false, SessionAttached: true, Dead: true},
	}
	killed := withCloseRunDeps(t, panes)

	if err := closeRunCmd([]string{"@2"}); err != nil {
		t.Fatalf("closeRunCmd = %v, want it to succeed", err)
	}
	if len(*killed) != 1 || (*killed)[0] != "@2" {
		t.Errorf("killed = %v, want [@2]", *killed)
	}
}

// TestCloseRunRefusesANonWindowID pins the hole the windowIDPattern
// check closes: kill-window resolves any tmux target, so a window named
// by anything but its id - a window name, an index, "session:window" -
// would slip past the focus check (which can only match a WindowID) and
// kill the very window the user was reading.
func TestCloseRunRefusesANonWindowID(t *testing.T) {
	panes := []tmux.Pane{
		{PaneID: "%1", SessionID: "$0", WindowID: "@1", WindowName: "victim", Active: true, SessionAttached: true},
	}
	for _, target := range []string{"victim", "alpha:0", "0", "@1x", "-t"} {
		killed := withCloseRunDeps(t, panes)
		if err := closeRunCmd([]string{target}); err == nil {
			t.Errorf("closeRunCmd(%q) = nil error, want a refusal: only a window id may be closed", target)
		}
		if len(*killed) != 0 {
			t.Errorf("closeRunCmd(%q) killed %v", target, *killed)
		}
	}
}

// TestCloseRunRefusesTheLastWindow pins the guard on the other way to
// lose what the user was reading: kill-window on a session's only window
// destroys the session, every other pane in it, and the client's view of
// all of it.
func TestCloseRunRefusesTheLastWindow(t *testing.T) {
	// Not focused - nobody is attached - so only the last-window rule can
	// save it.
	panes := []tmux.Pane{{PaneID: "%1", SessionID: "$0", WindowID: "@1", Active: true}}
	killed := withCloseRunDeps(t, panes)

	if err := closeRunCmd([]string{"@1"}); err != nil {
		t.Fatalf("closeRunCmd on a session's last window = %v, want no error (a skip, not a failure)", err)
	}
	if len(*killed) != 0 {
		t.Errorf("killWindow called for %v, want a session's only window left alone", *killed)
	}
}

func TestCloseRunRequiresOneArg(t *testing.T) {
	withCloseRunDeps(t, nil)
	for _, args := range [][]string{{}, {"@1", "@2"}, {""}} {
		if err := closeRunCmd(args); err == nil {
			t.Errorf("closeRunCmd(%v) = nil error, want a usage error", args)
		}
	}
}
