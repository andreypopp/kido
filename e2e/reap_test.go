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

// windowExists reports whether windowID is still a window of the inner
// server, anywhere.
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

// subagentWindow opens a window in session that looks to kido exactly
// like one `kido spawn` created: marked with @kido_subagent, keeping its
// pane after the command exits (remain-on-exit, which tmux.NewWindow sets
// for the same reason), and running a command that reports itself as a
// subagent through `kido agent-status` before becoming a long sleep.
//
// The report runs inside the pane rather than out of band, so the pid it
// records is that sleep's own - which is what makes killing the pane
// leave behind precisely the dead-pid record every live sidebar deletes
// on its next 100ms poll.
func (h *harness) subagentWindow(session, name, sessionID, instance, parentInstance string) (paneID, windowID string) {
	h.t.Helper()
	script := fmt.Sprintf("%s agent-status --agent pi --session %s --status idle "+
		"--instance %s --parent-instance %s; exec sleep 300",
		kidoBin, sessionID, instance, parentInstance)
	paneID = h.newWindow(session, name, "sh", "-c", script)
	h.waitPaneCommand(paneID, "sleep")
	windowID = h.windowID(paneID)
	h.in("set-window-option", "-t", windowID, "remain-on-exit", "on")
	h.in("set-option", "-w", "-t", windowID, "@kido_subagent", "parent="+parentInstance+" depth=1")
	return paneID, windowID
}

// liveParent records an agent with the given instance on session's own
// pane, out of band so the pid it records is the test binary's and stays
// alive for the whole test.
//
// A test about a finished subagent needs one: without a live parent the
// subagent is also an orphan, its window satisfies the dead-parent rule
// as well as the finished rule, and the test passes on whichever fires
// first - which is how the first draft of these tests passed.
func (h *harness) liveParent(session, instance string) {
	h.t.Helper()
	pane := h.in("display-message", "-p", "-t", session+":", "#{pane_id}")
	h.agentStatus(instance+"-parent-e2e", pane, "pi", "idle", "--instance", instance)
}

// killPane SIGKILLs the process in paneID and waits for it to go: the
// case no linger helper and no in-process poll can cover, since neither
// runs when a subagent is killed outright.
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

// runKido runs a kido command in a one-shot window of session and returns
// its output once it has written something. A fresh window rather than
// the client's own pane: several of these tests have the client looking
// at the very window under test, and typing there would land in it.
func (h *harness) runKido(session, outName string, args ...string) string {
	h.t.Helper()
	outFile := filepath.Join(h.dir, outName)
	script := fmt.Sprintf("%s %s > %s 2>&1; echo rc=$? >> %s",
		kidoBin, strings.Join(args, " "), outFile, outFile)
	h.newWindow(session, "", "sh", "-c", script)
	return h.waitFileNonEmpty(outFile)
}

// stays asserts that cond keeps holding for a while: the shape every
// "this window must be left alone" assertion needs, since a window that
// is never closed and one that has not been closed yet look identical at
// any single instant.
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

// TestSidebarReapsFinishedSubagentWindow is the lifecycle's backstop as
// it actually runs: a live sidebar, polling the same state directory as
// everything else, and no `kido reap` typed by anybody.
//
// It is written against the race that broke the first design. The sidebar
// calls state.Load every 100ms, and Load deletes a dead-pid record as a
// side effect of reading it, so a sweep that needed that record lost it
// within a tick of the subagent dying - which is why this test waits for
// the record to be gone *first* and only then for the window to close.
// Reaping from the @kido_subagent mark and #{pane_dead} instead needs no
// record at all, and the assertions below pass in that order or not at
// all.
func TestSidebarReapsFinishedSubagentWindow(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	const childSession = "reap-child-e2e"
	h.liveParent("alpha", "root-inst")
	paneID, windowID := h.subagentWindow("alpha", "kid-e2e", childSession, "child-inst", "root-inst")
	stateFile := filepath.Join(h.stateDir, childSession+".json")
	h.waitFor(func() bool { _, err := os.Stat(stateFile); return err == nil }, settle,
		msgf("the subagent's state record %s to be written", stateFile))
	// Running, with its parent alive: nothing about it is finished, and a
	// sweep that closed it here would be closing every subagent window in
	// the session the moment it opened.
	h.stays(func() bool { return h.windowExists(windowID) },
		"a running subagent's window was closed")

	h.killPane(paneID)

	h.waitFor(func() bool { _, err := os.Stat(stateFile); return os.IsNotExist(err) }, settle,
		msgf("the sidebar's own state.Load to delete the dead subagent's record %s", stateFile))
	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("the sidebar's poll to close window %s, whose record it has already deleted", windowID))
}

// TestReapLeavesUnmarkedWindowAlone pins the other half of why a sweep
// reads tmux rather than kido's state: pane ids restart at %0 on every
// new tmux server while state files are global and outlive it, so a
// record left by a previous run names a pane some unrelated shell holds
// now. Here that record is live and claims a parent that does not exist -
// the strongest case rule 2 can be given - against a window nobody
// marked. Neither the sidebar's sweep nor `kido reap` may touch it.
func TestReapLeavesUnmarkedWindowAlone(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	paneID := h.newWindow("alpha", "bystander", "sh", "-c", "exec sleep 600")
	h.waitPaneCommand(paneID, "sleep")
	windowID := h.windowID(paneID)
	// Recorded out of band, so the pid is this test binary's: a live
	// subagent record, naming an orphan's parent, pointing at a window
	// kido never created.
	h.agentStatus("stale-e2e", paneID, "pi", "idle",
		"--instance", "stale-inst", "--parent-instance", "vanished-inst")

	if out := h.runKido("alpha", "reap.out", "reap"); !strings.Contains(out, "rc=0") {
		t.Errorf("kido reap output = %q, want a clean exit", out)
	}
	h.stays(func() bool { return h.windowExists(windowID) },
		"an unmarked window was closed: only a window kido spawn marked may be reaped")
}

// TestReapNeverClosesASessionsLastWindow: closing it destroys the session
// itself (verified against a real server), taking every client attached
// to it. A finished subagent that is all a session has left is a leaked
// window; it is not worth a session.
func TestReapNeverClosesASessionsLastWindow(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	h.in("new-session", "-d", "-s", "solo", "-c", h.dir, "sh", "-c", "exec sleep 300")
	h.waitRow("solo")
	paneID := h.in("list-panes", "-t", "solo", "-F", "#{pane_id}")
	windowID := h.windowID(paneID)
	h.in("set-window-option", "-t", windowID, "remain-on-exit", "on")
	h.in("set-option", "-w", "-t", windowID, "@kido_subagent", "parent=root-inst depth=1")
	h.killPane(paneID)

	h.runKido("alpha", "last.out", "reap")
	h.stays(func() bool { return h.windowExists(windowID) },
		"a session's only window was closed, which destroys the session")
	if !strings.Contains(h.in("list-sessions", "-F", "#{session_name}"), "solo") {
		t.Error("session solo is gone; closing its last window destroyed it")
	}
}

// TestFocusedWindowIsReapedOnceTheUserLeaves: the linger helper checks
// focus once and gives up, so a user reading the window when it fires
// would leak it for good without the sweep. The sweep runs on every
// sidebar poll with the same focus rule, so the window is collected the
// moment they switch away - and not one moment before.
func TestFocusedWindowIsReapedOnceTheUserLeaves(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	const childSession = "linger-child-e2e"
	h.liveParent("alpha", "root-inst")
	paneID, windowID := h.subagentWindow("alpha", "linger-e2e", childSession, "child-inst", "root-inst")
	home := h.activeWindowID("alpha")

	// The user switches over to read the subagent's last screen.
	h.in("switch-client", "-c", h.client, "-t", windowID)
	h.waitFor(func() bool { return h.activeWindowID("alpha") == windowID }, settle,
		msgf("client to switch to window %s", windowID))
	h.killPane(paneID)

	// The linger helper fires while they are still there, and gives up.
	if out := h.runKido("alpha", "linger.out", "close-window", windowID); !strings.Contains(out, "current window") {
		t.Errorf("kido close-window output = %q, want it to say it left a focused window alone", out)
	}
	h.stays(func() bool { return h.windowExists(windowID) },
		"the window the user is reading was closed")

	h.in("switch-client", "-c", h.client, "-t", home)
	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("window %s to be collected on a later sweep, now that the user has left it", windowID))
}

// TestSidebarCancelsSubagentOfDeadParent is the second rule, which is the
// one that still needs a state record: nothing in tmux knows who spawned
// whom. The subagent here is perfectly healthy - its process is running,
// its pane is not dead - and is closed because the agent that spawned it
// is gone, which is the cancellation the sweep's second rule provides
// when the in-process poll never gets to run.
func TestSidebarCancelsSubagentOfDeadParent(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	// A parent whose pid can actually die: reported from inside its own
	// pane, unlike liveParent's.
	parentScript := fmt.Sprintf("%s agent-status --agent pi --session parent-e2e --status idle "+
		"--instance root-inst; exec sleep 300", kidoBin)
	parentPane := h.newWindow("alpha", "parent-e2e", "sh", "-c", parentScript)
	h.waitPaneCommand(parentPane, "sleep")

	_, windowID := h.subagentWindow("alpha", "kid-e2e", "cancel-child-e2e", "child-inst", "root-inst")
	h.stays(func() bool { return h.windowExists(windowID) },
		"a subagent's window was closed while its parent was still alive")

	h.killPane(parentPane)
	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("the sidebar's poll to cancel subagent window %s, whose parent is gone", windowID))
}

// TestCloseWindowLeavesFocusedWindowAlone checks `kido close-window`
// against a real tmux server: a window the client has actually switched
// to must be left open, since the user may have gone there to read a
// finishing subagent's last screen.
func TestCloseWindowLeavesFocusedWindowAlone(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	paneID := h.newWindow("alpha", "focus-e2e", "sh", "-c", "exec sleep 300")
	windowID := h.windowID(paneID)

	h.in("switch-client", "-c", h.client, "-t", windowID)
	h.waitFor(func() bool { return h.activeWindowID("alpha") == windowID }, settle,
		msgf("client to switch to window %s", windowID))

	h.runKido("alpha", "close.out", "close-window", windowID)

	if !h.windowExists(windowID) {
		t.Errorf("window %s was closed although the client had it focused", windowID)
	}
}
