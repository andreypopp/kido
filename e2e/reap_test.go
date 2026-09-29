package e2e

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func (h *harness) windowExists(windowID string) bool {
	h.t.Helper()
	for _, line := range strings.Split(h.in("list-windows", "-a", "-F", "#{window_id}"), "\n") {
		if line == windowID {
			return true
		}
	}
	return false
}

func (h *harness) windowID(paneID string) string {
	h.t.Helper()
	return h.in("display-message", "-p", "-t", paneID, "#{window_id}")
}

// subagentWindow opens a window that looks to kido exactly like one
// `kido spawn_subagent` created: @kido_run marked, remain-on-exit kept,
// reporting itself through `kido agent-status` from inside the pane (so
// the recorded pid is the sleep's own) before becoming a long sleep.
func (h *harness) subagentWindow(session, name, sessionID, parentSession string) (paneID, windowID string) {
	h.t.Helper()
	script := fmt.Sprintf("%s agent-status --agent pi --session %s --status idle "+
		"--parent-session %s; exec sleep 300",
		kidoBin, sessionID, parentSession)
	paneID = h.newWindow(session, name, "sh", "-c", script)
	h.waitPaneCommand(paneID, "sleep")
	windowID = h.windowID(paneID)
	h.in("set-window-option", "-t", windowID, "remain-on-exit", "on")
	h.in("set-option", "-p", "-t", paneID, "@kido_run", sessionID)
	return paneID, windowID
}

// liveParent records an agent on session's own pane, out of band so the
// pid is the test binary's and stays alive. Needed by any finished-
// subagent test: without it the subagent is also an orphan, and the test
// could pass on the dead-parent rule firing first instead of the one
// under test - how the first draft of these tests passed. Also needed by
// spawn_subagent callers with an invented parent: kido refuses to create
// the window unless the parent session names somebody alive.
func (h *harness) liveParent(session, sessionID string) {
	h.t.Helper()
	pane := h.in("display-message", "-p", "-t", session+":", "#{pane_id}")
	h.agentStatus(sessionID, pane, "pi", "idle")
}

// killPane covers the case no linger helper or in-process poll can:
// neither runs when a subagent is killed outright.
func (h *harness) killPane(paneID string) {
	h.t.Helper()
	pid, err := strconv.Atoi(h.in("display-message", "-p", "-t", paneID, "#{pane_pid}"))
	if err != nil {
		h.t.Fatal(err)
	}
	if err := syscall.Kill(pid, syscall.SIGKILL); err != nil {
		h.t.Fatal(err)
	}
	h.waitFor(func() bool { return syscall.Kill(pid, 0) == syscall.ESRCH }, settle,
		msgf("pid %d to exit", pid))
}

// runKido runs in a fresh window, not the client's own pane, since some
// tests have the client looking at the window under test already. It
// waits for the trailing "rc=<code>" line, not mere non-emptiness: a
// command that writes output before finishing can otherwise be read
// mid-write.
func (h *harness) runKido(session, outName string, args ...string) string {
	h.t.Helper()
	outFile := filepath.Join(h.dir, outName)
	script := fmt.Sprintf("%s %s > %s 2>&1; echo rc=$? >> %s",
		kidoBin, strings.Join(args, " "), outFile, outFile)
	h.newWindow(session, "", "sh", "-c", script)
	var content string
	h.waitFor(func() bool {
		b, err := os.ReadFile(outFile)
		if err != nil || !strings.Contains(string(b), "rc=") {
			return false
		}
		content = string(b)
		return true
	}, settle, func() string {
		b, _ := os.ReadFile(outFile)
		return fmt.Sprintf("%s to contain an \"rc=\" line, got %q", outFile, string(b))
	})
	return content
}

// stays asserts cond keeps holding for a while: a window never closed
// and one not closed yet look identical at any single instant.
func (h *harness) stays(cond func() bool, why string) {
	h.t.Helper()
	deadline := time.Now().Add(2 * time.Second) // the harness's linger is 1s
	for time.Now().Before(deadline) {
		if !cond() {
			h.t.Fatalf("%s\n%s", why, h.diagnose())
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// The lifecycle's backstop as it actually runs: a live sidebar polling,
// no `kido reap` typed. Written against the race that broke the first
// design - state.Load deletes a dead-pid record as a side effect of
// reading it, so a sweep needing that record lost it within a tick of
// the subagent dying. This test waits for the record gone *first* and
// only then for the window to close: reaping from @kido_run and
// #{pane_dead} needs no record at all, and passes in that order or not.
func TestSidebarReapsFinishedSubagentWindow(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	const childSession = "reap-child-e2e"
	h.liveParent("alpha", "root-e2e")
	paneID, windowID := h.subagentWindow("alpha", "kid-e2e", childSession, "root-e2e")
	stateFile := filepath.Join(h.stateDir, childSession+".json")
	h.waitFor(func() bool { _, err := os.Stat(stateFile); return err == nil }, settle,
		msgf("the subagent's state record %s to be written", stateFile))
	h.stays(func() bool { return h.windowExists(windowID) },
		"a running subagent's window was closed")

	h.killPane(paneID)

	h.waitFor(func() bool { _, err := os.Stat(stateFile); return os.IsNotExist(err) }, settle,
		msgf("the sidebar's own state.Load to delete the dead subagent's record %s", stateFile))
	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("the sidebar's poll to close window %s, whose record it has already deleted", windowID))
}

// Why a sweep reads tmux, not kido's state: pane ids restart at %0 on
// every new server while state files outlive it, so a stale record can
// name a pane some unrelated shell holds now. Here that record is live
// and claims a dead parent - the strongest case rule 2 can be given -
// against a window nobody marked, which neither sweep may touch.
func TestReapLeavesUnmarkedWindowAlone(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	paneID := h.newWindow("alpha", "bystander", "sh", "-c", "exec sleep 600")
	h.waitPaneCommand(paneID, "sleep")
	windowID := h.windowID(paneID)
	// Live record naming an orphan's parent, pointing at an unmarked window.
	h.agentStatus("stale-e2e", paneID, "pi", "idle",
		"--parent-session", "vanished-e2e")

	if out := h.runKido("alpha", "reap.out", "reap"); !strings.Contains(out, "rc=0") {
		t.Errorf("kido reap output = %q, want a clean exit", out)
	}
	h.stays(func() bool { return h.windowExists(windowID) },
		"an unmarked window was closed: only a window kido spawn_subagent marked may be reaped")
}

// Closing a session's last window destroys the session itself (verified
// against a real server), taking every client attached to it; a
// finished subagent that is all a session has left is a leaked window,
// not worth a session.
func TestReapNeverClosesASessionsLastWindow(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	h.in("new-session", "-d", "-s", "solo", "-c", h.dir, "sh", "-c", "exec sleep 300")
	h.waitRow("solo")
	paneID := h.in("list-panes", "-t", "solo", "-F", "#{pane_id}")
	windowID := h.windowID(paneID)
	h.in("set-window-option", "-t", windowID, "remain-on-exit", "on")
	h.in("set-option", "-p", "-t", paneID, "@kido_run", "solo-e2e")
	h.killPane(paneID)

	h.runKido("alpha", "last.out", "reap")
	h.stays(func() bool { return h.windowExists(windowID) },
		"a session's only window was closed, which destroys the session")
	if !strings.Contains(h.in("list-sessions", "-F", "#{session_name}"), "solo") {
		t.Error("session solo is gone; closing its last window destroyed it")
	}
}

// The linger helper checks focus once and gives up, so a user reading
// the window when it fires would leak it for good without the sweep,
// which runs the same focus rule on every poll and collects the window
// the moment they switch away.
func TestFocusedWindowIsReapedOnceTheUserLeaves(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	const childSession = "linger-child-e2e"
	h.liveParent("alpha", "root-e2e")
	paneID, windowID := h.subagentWindow("alpha", "linger-e2e", childSession, "root-e2e")
	home := h.activeWindowID("alpha")

	h.in("switch-client", "-c", h.client, "-t", windowID) // read the subagent's last screen
	h.waitFor(func() bool { return h.activeWindowID("alpha") == windowID }, settle,
		msgf("client to switch to window %s", windowID))
	h.killPane(paneID)

	if out := h.runKido("alpha", "linger.out", "close-run", windowID); !strings.Contains(out, "current window") {
		t.Errorf("kido close-run output = %q, want it to say it left a focused window alone", out)
	}
	h.stays(func() bool { return h.windowExists(windowID) },
		"the window the user is reading was closed")

	h.in("switch-client", "-c", h.client, "-t", home)
	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("window %s to be collected on a later sweep, now that the user has left it", windowID))
}

func (h *harness) paneDead(paneID string) bool {
	h.t.Helper()
	return h.in("display-message", "-p", "-t", paneID, "#{pane_dead}") == "1"
}

func (h *harness) paneExists(paneID string) bool {
	h.t.Helper()
	for _, line := range strings.Split(h.in("list-panes", "-a", "-F", "#{pane_id}"), "\n") {
		if line == paneID {
			return true
		}
	}
	return false
}

// The incident the unit of collection changed for: a shell split into a
// subagent's window whose run then finished. When the window was the
// unit, a live pane in it blocked collection entirely and the run's dead
// pane sat there until the user left. The unit is the run's pane now,
// leaving an ordinary, unmarked window behind. Also still tests the
// older bug: remain-on-exit is the run pane's alone (tmux.NewWindow's
// set-option -p), so the split closes on exit instead of a second corpse.
func TestSplitPaneSurvivesAFinishedRunAndTheWindowGoesPlain(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	// Both ends wait on a file rather than a duration: a pane dead for
	// exactly one linger is a window a loaded runner's polls can miss
	// whole (measured: macOS CI saw the pane collected before it saw it dead).
	finish := filepath.Join(h.dir, "splitrun-finish")
	stop := filepath.Join(h.dir, "splitrun-stop")
	runWindowID, runPaneID, runID := h.asyncBashIDs(nil, "splitrun",
		"sh", "-c", fmt.Sprintf("while [ ! -f %s ]; do sleep 0.1; done", finish))
	splitPaneID := h.in("split-window", "-P", "-F", "#{pane_id}", "-t", runWindowID,
		"-c", h.dir, "sh", "-c", fmt.Sprintf("while [ ! -f %s ]; do sleep 0.1; done", stop))
	h.waitRow("splitrun") // drawn before collection, so its later absence means something

	if err := os.WriteFile(finish, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	info := h.waitOutcome(runID)
	if info.Outcome != "completed" {
		t.Fatalf("kido runs reports outcome %q, want completed", info.Outcome)
	}
	if h.paneDead(splitPaneID) {
		t.Fatalf("split pane %s is dead already; it should still be waiting on %s", splitPaneID, stop)
	}

	h.waitFor(func() bool { return !h.paneExists(runPaneID) }, settle,
		msgf("the run's dead pane %s to be collected once the linger has passed", runPaneID))
	if !h.windowExists(runWindowID) {
		t.Fatalf("window %s is gone; collecting the run's pane must leave the user's split standing", runWindowID)
	}
	if !h.paneExists(splitPaneID) {
		t.Fatalf("the user's split %s went with the run's pane", splitPaneID)
	}

	// @kido_run lived on the run's pane alone, so with that pane gone the
	// window carries no run pane at all and the sidebar draws it plain:
	// session, client's shell, user's split, with no row for the run.
	plain := func() bool {
		// rowIndex answers 0 for a row that is not there; it is 1-based.
		return len(h.rows()) == 3 && h.rowIndex("splitrun") == 0 && h.rowIndex("completed") == 0
	}
	h.waitFor(plain, settle, func() string {
		return fmt.Sprintf("window %s to be drawn as a plain window with the user's shell, rows are %q",
			runWindowID, h.rows())
	})
	h.stays(plain, fmt.Sprintf("the sidebar went back to drawing window %s as a run: %q", runWindowID, h.rows()))

	if err := os.WriteFile(stop, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	h.waitFor(func() bool { return !h.windowExists(runWindowID) }, settle,
		msgf("window %s to close when its last pane exits", runWindowID))
}

// The second rule, the one that still needs a state record: nothing in
// tmux knows who spawned whom. The subagent here is perfectly healthy -
// running, not dead - and is closed only because its parent is gone.
func TestSidebarCancelsSubagentOfDeadParent(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	// Reported from inside its own pane, so its pid can actually die (unlike liveParent's).
	parentScript := fmt.Sprintf("%s agent-status --agent pi --session parent-e2e --status idle"+
		"; exec sleep 300", kidoBin)
	parentPane := h.newWindow("alpha", "parent-e2e", "sh", "-c", parentScript)
	h.waitPaneCommand(parentPane, "sleep")

	_, windowID := h.subagentWindow("alpha", "kid-e2e", "cancel-child-e2e", "parent-e2e")
	h.stays(func() bool { return h.windowExists(windowID) },
		"a subagent's window was closed while its parent was still alive")

	h.killPane(parentPane)
	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("the sidebar's poll to cancel subagent window %s, whose parent is gone", windowID))
}

// A same-pane collision - a newer record sharing the parent's own pane,
// the shape a `pi --print` inheriting TMUX_PANE produces (state.beats) -
// must never close a healthy child's window. The collision decides only
// which record owns a pane; the sweep asks whether a session is running
// anywhere, and both records stay on disk and alive throughout.
func TestSidebarSurvivesAParentPaneCollision(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	parentScript := fmt.Sprintf("%s agent-status --agent pi --session parent-collision-e2e --status idle"+
		"; exec sleep 300", kidoBin)
	parentPane := h.newWindow("alpha", "parent-collision-e2e", "sh", "-c", parentScript)
	h.waitPaneCommand(parentPane, "sleep")

	childScript := fmt.Sprintf("%s agent-status --agent pi --session child-collision-e2e --status idle "+
		"--parent-session parent-collision-e2e; exec sleep 300", kidoBin)
	childPane := h.newWindow("alpha", "kid-collision-e2e", "sh", "-c", childScript)
	h.waitPaneCommand(childPane, "sleep")
	windowID := h.windowID(childPane)
	h.in("set-window-option", "-t", windowID, "remain-on-exit", "on")
	h.in("set-option", "-p", "-t", childPane, "@kido_run", "child-collision-e2e")

	// An intruder claims the parent's own pane with a newer timestamp, the
	// same way a `pi --print` inheriting TMUX_PANE does, left in place for
	// the whole test.
	h.agentStatus("intruder-collision-e2e", parentPane, "pi", "idle")

	h.stays(func() bool { return h.windowExists(windowID) },
		"a subagent's window was closed by a pane collision on its parent's own record, though the parent's own record was on disk and its process alive")
}

// The orphan rule from a one-shot `kido reap`: it could not apply while
// the rule needed the same parent missing on two sweeps, since a fresh
// process only ever sweeps once. One reading of every live record
// decides it now, so the operator's command does what the sidebar's
// poll does.
func TestReapCancelsSubagentOfDeadParent(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	parentScript := fmt.Sprintf("%s agent-status --agent pi --session parent-oneshot-e2e --status idle"+
		"; exec sleep 300", kidoBin)
	parentPane := h.newWindow("alpha", "parent-oneshot-e2e", "sh", "-c", parentScript)
	h.waitPaneCommand(parentPane, "sleep")

	_, windowID := h.subagentWindow("alpha", "kid-oneshot-e2e", "oneshot-child-e2e",
		"parent-oneshot-e2e")
	// Hide the column: rule 2 fires on one reading now, so a sidebar still
	// running would race `kido reap` for the window.
	h.in("set", "-g", "side-status", "off")
	h.waitFor(func() bool { return !h.sidebarVisible() }, settle, msgf("the sidebar to go away"))
	h.killPane(parentPane)

	if out := h.runKido("alpha", "orphan.out", "reap"); !strings.Contains(out, "rc=0") {
		t.Fatalf("kido reap output = %q, want a clean exit", out)
	}
	if h.windowExists(windowID) {
		t.Errorf("window %s is still open after one `kido reap`, though its parent is gone", windowID)
	}
}

// A window the client has actually switched to must be left open, since
// the user may have gone there to read a finishing subagent's last screen.
func TestCloseRunLeavesFocusedWindowAlone(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	paneID := h.newWindow("alpha", "focus-e2e", "sh", "-c", "exec sleep 300")
	windowID := h.windowID(paneID)

	h.in("switch-client", "-c", h.client, "-t", windowID)
	h.waitFor(func() bool { return h.activeWindowID("alpha") == windowID }, settle,
		msgf("client to switch to window %s", windowID))

	h.runKido("alpha", "close.out", "close-run", windowID)

	if !h.windowExists(windowID) {
		t.Errorf("window %s was closed although the client had it focused", windowID)
	}
}
