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

func TestReapSkipsTopLevelPiMark(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.hideSidebar()
	top := h.promptPane("alpha", "top-level")
	sub, _ := h.subagentWindow("alpha", "close-child", "close-child", "")
	h.in("join-pane", "-d", "-s", sub, "-t", top)
	h.in("set-option", "-p", "-t", sub, "remain-on-exit", "on")
	h.killPane(sub)
	h.waitFor(func() bool { return h.paneDead(sub) }, settle, msgf("child pane to die"))
	var out string
	h.waitFor(func() bool {
		out = h.runKido("alpha", "reap.out", "reap")
		return !h.paneExists(sub)
	}, settle, msgf("kido reap to collect dead child %s behind the live Pi mark", sub))
	if !h.paneExists(top) {
		t.Fatalf("kido reap killed the top-level Pi pane: %q", out)
	}
}

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

// subagentWindow opens a window that looks to kido exactly like one a
// run-child created: @kido_run marked, remain-on-exit kept, and a run meta
// naming the pane.
func (h *harness) subagentWindow(session, name, sessionID, parentSession string) (paneID, windowID string) {
	h.t.Helper()
	if parentSession != "" {
		for _, line := range strings.Split(h.in("list-panes", "-a", "-F", "#{pane_id}\t#{@kido_session}"), "\n") {
			id, sess, ok := strings.Cut(line, "\t")
			if ok && sess == parentSession {
				parentSession = id
			}
		}
	}
	paneID = h.newWindow(session, name, "sh", "-c", "exec sleep 300")
	windowID = h.windowID(paneID)
	h.in("set-window-option", "-t", windowID, "remain-on-exit", "on")
	h.in("set-option", "-p", "-t", paneID, "@kido_run", sessionID)
	h.agentRunMeta(sessionID, paneID, name, parentSession)
	h.waitPaneCommand(paneID, "sleep")
	return paneID, windowID
}

// liveParent gives session's own pane a pi root and the four options, so
// it is a local pi and a Pane parent that has not ended.
func (h *harness) liveParent(session, sessionID string) {
	h.t.Helper()
	pane := h.firstPane(session)
	h.piRoot(pane)
	h.agentStatus(sessionID, pane)
}

// killPane simulates a subagent killed outright, which no in-process
// shutdown path can do.
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
	return h.runScript(session, outName, kidoBin+" "+strings.Join(args, " "))
}

// runScript is runKido for any sh command line: an environment
// assignment ahead of kido, or a command that is not kido at all.
func (h *harness) runScript(session, outName, script string) string {
	h.t.Helper()
	outFile := filepath.Join(h.dir, outName)
	if err := os.Remove(outFile); err != nil && !os.IsNotExist(err) {
		h.t.Fatal(err)
	}
	h.newWindow(session, "", "sh", "-c", fmt.Sprintf("%s > %s 2>&1; echo rc=$? >> %s", script, outFile, outFile))
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

// typeScript is runScript typed into an existing shell pane, for a
// command whose caller must be that pane: the agent recorded on it.
func (h *harness) typeScript(pane, outName, script string) string {
	h.t.Helper()
	outFile := filepath.Join(h.dir, outName)
	h.in("send-keys", "-t", pane, "-l", fmt.Sprintf("%s > %s 2>&1; echo rc=$? >> %s", script, outFile, outFile))
	h.in("send-keys", "-t", pane, "Enter")
	return h.waitFileContains(outFile, "rc=")
}

// stays asserts cond keeps holding for a while: a window never closed
// and one not closed yet look identical at any single instant.
func (h *harness) stays(d time.Duration, cond func() bool, why string) {
	h.t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if !cond() {
			h.t.Fatalf("%s\n%s", why, h.diagnose())
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// The lifecycle's backstop as it actually runs: a live sidebar polling,
// no `kido reap` typed: reaping from @kido_run and #{pane_dead} needs no
// live record at all.
func TestSidebarReapsFinishedSubagentWindow(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	const childSession = "reap-child-e2e"
	h.liveParent("alpha", "root-e2e")
	paneID, windowID := h.subagentWindow("alpha", "kid-e2e", childSession, "root-e2e")
	h.stays(quiet, func() bool { return h.windowExists(windowID) },
		"a running subagent's window was closed")

	h.killPane(paneID)

	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("the sidebar's poll to close window %s", windowID))
}

// The sweep acts only on a marked pane whose run's meta names it. Here a
// pane carries @kido_run for a run whose meta names a different pane, so
// neither the sidebar nor `kido reap` may touch it.
func TestReapLeavesAWindowItDidNotCreate(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	paneID := h.newWindow("alpha", "bystander", "sh", "-c", "exec sleep 600")
	h.waitPaneCommand(paneID, "sleep")
	windowID := h.windowID(paneID)
	h.piRoot(paneID)
	h.agentRunMeta("stale-e2e", "%999", "", "vanished-e2e")
	h.in("set-option", "-p", "-t", paneID, "@kido_run", "stale-e2e")
	h.agentStatus("stale-e2e", paneID)

	if out := h.runKido("alpha", "reap.out", "reap"); !strings.Contains(out, "rc=0") {
		t.Errorf("kido reap output = %q, want a clean exit", out)
	}
	h.stays(linger, func() bool { return h.windowExists(windowID) },
		"a window kido did not create was closed: only a run's own pane may be reaped")
	h.in("set-window-option", "-t", windowID, "remain-on-exit", "on")
	h.killPane(paneID)
	h.stays(linger, func() bool { return h.windowExists(windowID) },
		"a dead pane kido did not create was collected: only a run's own pane may be reaped")
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
	h.agentRunMeta("solo-e2e", paneID, "", "")
	h.killPane(paneID)

	h.runKido("alpha", "last.out", "reap")
	h.stays(linger, func() bool { return h.windowExists(windowID) },
		"a session's only window was closed, which destroys the session")
	if !strings.Contains(h.in("list-sessions", "-F", "#{session_name}"), "solo") {
		t.Error("session solo is gone; closing its last window destroyed it")
	}

	// A run's pane in that same only window is still collected when the user
	// split it: the pane goes, the split and the session stay.
	h.in("new-session", "-d", "-s", "split", "-c", h.dir, "sh", "-c", "exec sleep 300")
	h.waitRow("split")
	paneID = h.in("list-panes", "-t", "split", "-F", "#{pane_id}")
	windowID = h.windowID(paneID)
	h.in("set-window-option", "-t", windowID, "remain-on-exit", "on")
	h.in("set-option", "-p", "-t", paneID, "@kido_run", "solo-split-e2e")
	h.agentRunMeta("solo-split-e2e", paneID, "", "")
	split := h.in("split-window", "-d", "-P", "-F", "#{pane_id}", "-t", windowID, "sh", "-c", "exec sleep 300")
	h.killPane(paneID)
	h.reap("solo-split.out")
	h.waitFor(func() bool { return !h.paneExists(paneID) }, settle,
		msgf("the run's dead pane %s to be collected from session solo's only window", paneID))
	if !h.paneExists(split) || !strings.Contains(h.in("list-sessions", "-F", "#{session_name}"), "split") {
		t.Errorf("the split %s or session split went with the run's pane", split)
	}
}

// The sweep runs its focus rule on every poll, so a user reading a
// finished run's window keeps it open and the next poll after they
// switch away collects it. The run recorded its own completion first:
// that outcome must survive the close, not become the sweep's guess.
func TestFocusedWindowIsReapedOnceTheUserLeaves(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	caller := h.firstPane("alpha")
	script := fmt.Sprintf(`sleep 0.5; %s run-outcome --result completed -- "$KIDO_RUN_ID"; sleep 1`,
		kidoBin)
	r := h.startRun(caller, "run", "--name", "completed-sweep-e2e", "--", "bash", "-c", script)
	runID := r.ID
	windowID := r.Window
	h.waitFor(func() bool { return h.runOutcome(runID) == "completed" }, settle,
		msgf("run %s to record its own completed outcome", runID))

	home := h.activeWindowID("alpha")
	h.in("switch-client", "-c", h.client, "-t", windowID) // read the run's last screen
	h.waitFor(func() bool { return h.activeWindowID("alpha") == windowID }, settle,
		msgf("client to switch to window %s", windowID))
	h.stays(quiet, func() bool { return h.windowExists(windowID) },
		"the focused window of a completed run was closed")
	if got := h.runOutcome(runID); got != "completed" {
		t.Errorf("run %s outcome = %q while focused, want %q", runID, got, "completed")
	}

	h.in("switch-client", "-c", h.client, "-t", home)
	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("window %s to be collected after the user left it", windowID))
	if got := h.runOutcome(runID); got != "completed" {
		t.Errorf("run %s outcome = %q after the sweep closed it, want %q (the sweep's guess must not overwrite it)",
			runID, got, "completed")
	}
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
// older bug: remain-on-exit is the run pane's alone (Tmux.Exec.new_window's
// set-option -p), so the split closes on exit instead of a second corpse.
func TestSplitPaneSurvivesAFinishedRunAndTheWindowGoesPlain(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	// Both ends wait on a file rather than a duration: a pane dead for
	// exactly one linger is a window a loaded runner's polls can miss
	// whole (measured: macOS CI saw the pane collected before it saw it dead).
	finish := filepath.Join(h.dir, "splitrun-finish")
	stop := filepath.Join(h.dir, "splitrun-stop")
	caller := h.firstPane("alpha")
	r := h.startRun(caller, "run", "--name", "splitrun", "--", "sh", "-c",
		fmt.Sprintf("while [ ! -f %s ]; do sleep 0.1; done", finish))
	runWindowID, runPaneID := r.Window, r.Pane
	runID := r.ID
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
	h.stays(quiet, plain, fmt.Sprintf("the sidebar went back to drawing window %s as a run: %q", runWindowID, h.rows()))

	if err := os.WriteFile(stop, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	h.waitFor(func() bool { return !h.windowExists(runWindowID) }, settle,
		msgf("window %s to close when its last pane exits", runWindowID))
}

// The second rule, the one that still needs a run record: nothing in
// tmux knows who spawned whom. The subagent here is perfectly healthy -
// running, not dead - and is closed only because its parent is gone.
func TestSidebarCancelsSubagentOfDeadParent(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	parentPane := h.newWindow("alpha", "parent-e2e", "sh", "-c", "exec sleep 300")
	h.agentRunMeta("parent-e2e", parentPane, "parent-e2e", "")
	h.waitPaneCommand(parentPane, "sleep")
	h.piRoot(parentPane)

	_, windowID := h.subagentWindow("alpha", "kid-e2e", "cancel-child-e2e", "parent-e2e")
	h.stays(quiet, func() bool { return h.windowExists(windowID) },
		"a subagent's window was closed while its parent was still alive")

	h.killPane(parentPane)
	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("the sidebar's poll to cancel subagent window %s, whose parent is gone", windowID))
}

// The orphan rule from a one-shot `kido reap`: one reading of the
// parent's run decides it, so the operator's command does what the
// sidebar's poll does.
func TestReapCancelsSubagentOfDeadParent(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	parentPane := h.newWindow("alpha", "parent-oneshot-e2e", "sh", "-c", "exec sleep 300")
	h.agentRunMeta("parent-oneshot-e2e", parentPane, "parent-oneshot-e2e", "")
	h.waitPaneCommand(parentPane, "sleep")
	h.piRoot(parentPane)

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

// Rule 1 waits out the linger before touching a finished run, and saves
// the run's screen only for a window it actually closes. The same
// `kido reap`, run with a linger the dead pane has not yet outlived and
// then with the harness's own 1s, is the pair.
func TestReapLeavesARunAloneWithinItsLinger(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.hideSidebar()

	caller := h.firstPane("alpha")
	r := h.startRun(caller, "run", "--name", "young-e2e", "--", "sh", "-c", "echo young-screen-e2e; exec sleep 300")
	runID := r.ID
	windowID := r.Window
	paneID := h.in("list-panes", "-t", windowID, "-F", "#{pane_id}")
	h.waitPaneText(paneID, "young-screen-e2e")
	h.killPane(paneID)

	h.runScript("alpha", "reap-young.out", "KIDO_LINGER_SECONDS=600 "+kidoBin+" reap")
	h.stays(linger, func() bool { return h.windowExists(windowID) },
		"a run's window was closed within its linger")
	if _, ok := h.runMeta("young", runID)["screen"]; ok {
		t.Errorf("run %s has a screen saved for a window the sweep left alone", runID)
	}

	h.runKido("alpha", "reap-old.out", "reap")
	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("`kido reap` to close window %s once its linger has passed", windowID))
	if screen, _ := h.runMeta("old", runID)["screen"].(string); !strings.Contains(screen, "young-screen-e2e") {
		t.Errorf("run %s screen = %q, want the closed window's last screen", runID, screen)
	}
}
