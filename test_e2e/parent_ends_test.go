package e2e

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// reportedChild spawns a subagent under root-e2e, which has an inbox so
// the child can tell it something, and has the child's own shell claim
// the run (its pid, like pi's) and send "report", "status", or nothing.
// The child then stays alive: ending it is the parent's decision.
func (h *harness) reportedChild(name, notice string) (runID, windowID string, parent *inbox) {
	h.t.Helper()
	parent = startInbox(h.t, "ok\n")
	childInbox := startInbox(h.t, "ok\n")
	say := ""
	switch notice {
	case "report":
		say = fmt.Sprintf("printf \"the work is done\" | %s tool notify_parent; ", kidoBin)
	case "status":
		say = fmt.Sprintf("printf \"the work is done\" | %s tool notify_parent --status; ", kidoBin)
	}
	script := fmt.Sprintf(
		`printf "\033]2;π - %%s\033\\\033]7501;state=idle:app=pi\033\\" %s; `+
			`PI_SESSION_ID="$KIDO_AGENT_RUN_ID" %s agent-status --inbox %s; %sexec sleep 300`,
		name, kidoBin, childInbox.Path, say)
	runID, windowID = h.spawnRun(name, script, "--inbox", parent.Path)
	record := filepath.Join(h.stateDir, "runs", runID, "pi.json")
	h.waitFor(func() bool { _, err := os.Stat(record); return err == nil }, settle,
		msgf("run %s's own record %s", runID, record))
	if notice != "" {
		h.waitFor(func() bool { return len(parent.Received()) == 1 }, settle,
			msgf("the child's notice to reach its parent"))
	}
	return runID, windowID, parent
}

// A child that reported stays alive after its turn settled. Nothing but
// its parent decides when it ends.
func TestReportedChildStaysAlive(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	runID, windowID, _ := h.reportedChild("reported-e2e", "report")
	paneID := h.in("list-panes", "-t", windowID, "-F", "#{pane_id}")
	h.stays(quiet, func() bool {
		return h.windowExists(windowID) && h.in("display-message", "-p", "-t", paneID, "#{pane_dead}") == "0"
	}, "a child that reported was ended by something other than its parent")
	if got := h.runOutcome(runID, "reported"); got != "running" {
		t.Errorf("run %s outcome = %q, want running: it stays alive until stopped", runID, got)
	}
}

// Stopping a child is the normal end of its work or a stop before it
// finished: one table, one server, three children.
func TestStopOutcomes(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	for _, c := range []struct {
		name, notice, outcome, run string
	}{
		{"stop-after-report-e2e", "report", "completed", "stop-after-reported"},
		{"stop-after-status-e2e", "status", "stopped", "stop-after-status"},
		{"stop-before-report-e2e", "", "stopped", "stop-before-reported"},
	} {
		runID, windowID, parent := h.reportedChild(c.name, c.notice)
		out := h.runKido("alpha", c.name+".out", "tool", "stop_run", runID)
		if !strings.Contains(out, "rc=0") {
			t.Fatalf("%s: kido tool stop_run = %q, want a successful stop", c.name, out)
		}
		h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
			msgf("%s: stopped child's window %s to close", c.name, windowID))
		if got := h.runOutcome(runID, c.run); got != c.outcome {
			t.Errorf("%s: run %s outcome = %q, want %q", c.name, runID, got, c.outcome)
		}
		wantReceived := 0
		if c.notice != "" {
			wantReceived = 1
		}
		if len(parent.Received()) != wantReceived {
			t.Errorf("%s: parent inbox = %q, want %d notice(s)", c.name, parent.Received(), wantReceived)
		}
		if c.notice != "report" {
			if _, err := os.Stat(filepath.Join(h.stateDir, "runs", runID, "report")); !os.IsNotExist(err) {
				t.Errorf("%s: a status notice left a report file (%v); only a real report may", c.name, err)
			}
		}
	}
}
