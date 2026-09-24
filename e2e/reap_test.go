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
// like one `kido spawn_subagent` created: marked with @kido_subagent, keeping its
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
//
// Every test that spawns through `kido spawn_subagent` with an invented
// parent needs one too, and for a related reason made into a refusal:
// kido now checks the instance names somebody alive before it creates
// the window (cmd/kido/spawn_subagent.go's liveInstance), rather than
// leaving the child to be closed by rule 2 seconds later.
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
// its output once the command has exited. A fresh window rather than the
// client's own pane: several of these tests have the client looking at
// the very window under test, and typing there would land in it.
//
// It waits for the trailing "rc=<code>" line rather than mere
// non-emptiness: a command that writes output before it is done - a
// notice line well ahead of its final "stopped ...", say - can otherwise
// be read mid-write, its exit code line not there yet even though the
// file already holds something.
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
		"an unmarked window was closed: only a window kido spawn_subagent marked may be reaped")
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
	if out := h.runKido("alpha", "linger.out", "close-run", windowID); !strings.Contains(out, "current window") {
		t.Errorf("kido close-run output = %q, want it to say it left a focused window alone", out)
	}
	h.stays(func() bool { return h.windowExists(windowID) },
		"the window the user is reading was closed")

	h.in("switch-client", "-c", h.client, "-t", home)
	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("window %s to be collected on a later sweep, now that the user has left it", windowID))
}

// paneDead reports whether tmux considers paneID a remain-on-exit corpse.
func (h *harness) paneDead(paneID string) bool {
	h.t.Helper()
	return h.in("display-message", "-p", "-t", paneID, "#{pane_dead}") == "1"
}

// paneExists reports whether paneID is still a pane of the inner server.
func (h *harness) paneExists(paneID string) bool {
	h.t.Helper()
	for _, line := range strings.Split(h.in("list-panes", "-a", "-F", "#{pane_id}"), "\n") {
		if line == paneID {
			return true
		}
	}
	return false
}

// windowMark is the @kido_subagent window option's value, empty for a
// window that carries none. Straight through h.tmux: show-options for an
// option that is not set exits nonzero, which h.in would fail the test
// over, and "not set" is exactly what half of this asks about.
func (h *harness) windowMark(windowID string) string {
	h.t.Helper()
	out, err := h.tmux(h.inner, "show-options", "-w", "-t", windowID, "@kido_subagent")
	if err != nil {
		return ""
	}
	return out
}

// TestSplitPaneSurvivesAFinishedRunAndTheWindowGoesPlain is the incident
// the unit of collection changed for, in the order the user hit it: they
// split a shell into a subagent's window and the run in it finished. The
// window was the unit then, so with a live pane in it nothing could be
// collected at all and the run's dead pane sat beside their shell until
// they left the window. The unit is the run's pane now, and what is left
// behind is an ordinary window: unmarked, drawn by the sidebar as the
// user's own, and closing when its last pane exits like any window.
//
// It is also still the test for the older bug underneath: remain-on-exit
// is the run pane's alone (tmux.NewWindow sets it with set-option -p), so
// the split closes on exit instead of becoming a second corpse.
func TestSplitPaneSurvivesAFinishedRunAndTheWindowGoesPlain(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	runWindowID, runPaneID, runID := h.asyncBashIDs(nil, "splitrun", "sleep", "1")
	// The split outlives the collection below by waiting on a file this
	// test creates, rather than on a duration: a sleep that happened to
	// end while the run's pane was being collected would be
	// indistinguishable from the window taking the split with it.
	stop := filepath.Join(h.dir, "splitrun-stop")
	splitPaneID := h.in("split-window", "-P", "-F", "#{pane_id}", "-t", runWindowID,
		"-c", h.dir, "sh", "-c", fmt.Sprintf("while [ ! -f %s ]; do sleep 0.1; done", stop))

	info := h.waitOutcome(runID)
	if info.Outcome != "completed" {
		t.Fatalf("kido runs reports outcome %q, want completed", info.Outcome)
	}
	h.waitFor(func() bool { return h.paneDead(runPaneID) }, settle,
		msgf("run pane %s to go dead once its command exits", runPaneID))
	if h.paneDead(splitPaneID) {
		t.Fatalf("split pane %s is dead already; it should still be waiting on %s", splitPaneID, stop)
	}
	// The sidebar draws the finished run before anything collects it, which
	// is what makes its absence below mean something.
	h.waitRow("splitrun")

	// The linger, and the sweep behind it, collect the run's dead pane and
	// nothing else.
	h.waitFor(func() bool { return !h.paneExists(runPaneID) }, settle,
		msgf("the run's dead pane %s to be collected once the linger has passed", runPaneID))
	if !h.windowExists(runWindowID) {
		t.Fatalf("window %s is gone; collecting the run's pane must leave the user's split standing", runWindowID)
	}
	if !h.paneExists(splitPaneID) {
		t.Fatalf("the user's split %s went with the run's pane", splitPaneID)
	}

	// With its run collected the window is nobody's subagent: unmarked, so
	// the tree stops nesting it, switch-window stops skipping it and no
	// later sweep considers it.
	h.waitFor(func() bool { return h.windowMark(runWindowID) == "" }, settle,
		msgf("window %s to be unmarked, is %q", runWindowID, h.windowMark(runWindowID)))
	// And the sidebar draws it as the plain window it now is: the session,
	// the client's own shell and the user's split, with no row left for the
	// run - neither its name nor the outcome its label carried, and no
	// nested block for a window that is nobody's subagent now.
	plain := func() bool {
		// rowIndex answers 0 for a row that is not there; it is 1-based.
		return len(h.rows()) == 3 && h.rowIndex("splitrun") == 0 && h.rowIndex("completed") == 0
	}
	h.waitFor(plain, settle, func() string {
		return fmt.Sprintf("window %s to be drawn as a plain window with the user's shell, rows are %q",
			runWindowID, h.rows())
	})
	h.stays(plain, fmt.Sprintf("the sidebar went back to drawing window %s as a run: %q", runWindowID, h.rows()))

	// The split exits on its own, and the window goes like any window:
	// nothing kido did left remain-on-exit on that pane.
	if err := os.WriteFile(stop, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	h.waitFor(func() bool { return !h.windowExists(runWindowID) }, settle,
		msgf("window %s to close when its last pane exits", runWindowID))
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

// TestSidebarSurvivesAParentPaneCollision is the regression e2e test for
// the actual incident: a same-pane collision - a newer record sharing
// the parent's own pane, exactly the shape a `pi --print` that inherited
// TMUX_PANE from its caller's pane produces (state.beats) - must never
// close a healthy child's window, however long the collision lasts.
//
// It is a test of what the sidebar hands its sweep, and of nothing else.
// The collision decides only which record owns a pane; the sweep asks
// whether an instance is running anywhere, and both records are on disk
// and alive throughout. The child names no parent pid: waiting a
// collision out, or checking a second pid, are gone, so a window kept
// open by either would prove nothing about what keeps it open now.
func TestSidebarSurvivesAParentPaneCollision(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	parentScript := fmt.Sprintf("%s agent-status --agent pi --session parent-collision-e2e --status idle "+
		"--instance root-inst; exec sleep 300", kidoBin)
	parentPane := h.newWindow("alpha", "parent-collision-e2e", "sh", "-c", parentScript)
	h.waitPaneCommand(parentPane, "sleep")

	childScript := fmt.Sprintf("%s agent-status --agent pi --session child-collision-e2e --status idle "+
		"--instance child-inst --parent-instance root-inst; exec sleep 300", kidoBin)
	childPane := h.newWindow("alpha", "kid-collision-e2e", "sh", "-c", childScript)
	h.waitPaneCommand(childPane, "sleep")
	windowID := h.windowID(childPane)
	h.in("set-window-option", "-t", windowID, "remain-on-exit", "on")
	h.in("set-option", "-w", "-t", windowID, "@kido_subagent", "parent=root-inst depth=1")

	// The collision: an intruder claims the parent's own pane with a
	// newer timestamp, the same way a `pi --print` inheriting TMUX_PANE
	// does. Left in place for the whole test - state.Load hands the
	// intruder that pane for as long as it reports, so a sidebar sweeping
	// a per-pane view would see no record for root-inst at all.
	h.agentStatus("intruder-collision-e2e", parentPane, "pi", "idle", "--instance", "intruder-inst")

	h.stays(func() bool { return h.windowExists(windowID) },
		"a subagent's window was closed by a pane collision on its parent's own record, though the parent's own record was on disk and its process alive")
}

// TestReapCancelsSubagentOfDeadParent is the orphan rule from a one-shot
// `kido reap`, which it could not apply while the rule needed to see the
// same parent missing on two sweeps: a fresh process only ever sweeps
// once. One reading of every live record decides it now, so the command
// an operator types does the same thing the sidebar's poll does.
//
// The sidebar in this session would eventually collect the window too,
// so the assertion is that `kido reap` returns having already closed it:
// the command's own output is what is waited on, and the window is
// checked the moment it comes back.
func TestReapCancelsSubagentOfDeadParent(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	parentScript := fmt.Sprintf("%s agent-status --agent pi --session parent-oneshot-e2e --status idle "+
		"--instance oneshot-root-inst; exec sleep 300", kidoBin)
	parentPane := h.newWindow("alpha", "parent-oneshot-e2e", "sh", "-c", parentScript)
	h.waitPaneCommand(parentPane, "sleep")

	_, windowID := h.subagentWindow("alpha", "kid-oneshot-e2e", "oneshot-child-e2e",
		"oneshot-child-inst", "oneshot-root-inst")
	// Hide the column first and wait for it to go, so nothing else is
	// sweeping: rule 2 fires on one reading now, so a sidebar still
	// running would race the command under test and could close the
	// window itself.
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

// TestCloseRunLeavesFocusedWindowAlone checks `kido close-run` against a
// real tmux server: a window the client has actually switched to must be
// left open, since the user may have gone there to read a finishing
// subagent's last screen.
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
