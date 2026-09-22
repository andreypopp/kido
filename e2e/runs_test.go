package e2e

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kido/internal/testutil"
)

// runInfo mirrors cmd/kido/runs.go's RunInfo, just the fields these tests
// read.
type runInfo struct {
	ID      string `json:"id"`
	Outcome string `json:"outcome"`
}

// spawnRun drives `kido spawn` with a fake command, exactly as runSpawn
// does, but returns the run id kido spawn's third output field now
// carries and lets the caller supply the fake command's script directly -
// runSpawn's own fixed "env; pwd; sleep" script does not exit on its own,
// which every test here needs control over.
func (h *harness) spawnRun(name, script string) (runID, windowID string) {
	h.t.Helper()
	outFile := filepath.Join(h.dir, name+".out")
	cmd := fmt.Sprintf("%s spawn --parent-pid 1 --parent-instance root-inst --name %s --task-file %s -- /bin/sh -c %s > %s 2>&1",
		kidoBin, name, h.writeTaskFile(name), shellQuote(script), outFile)
	h.sendLiteral(cmd)
	h.sendKeys("Enter")
	out := strings.TrimSpace(h.waitFileNonEmpty(outFile))
	fields := strings.Fields(out)
	if len(fields) != 3 {
		h.t.Fatalf("kido spawn printed %q, want \"<window id> <pane id> <run id>\"", out)
	}
	return fields[2], fields[0]
}

func (h *harness) writeTaskFile(name string) string {
	h.t.Helper()
	path := filepath.Join(h.dir, name+"-task.txt")
	if err := os.WriteFile(path, []byte("do the thing"), 0o644); err != nil {
		h.t.Fatal(err)
	}
	return path
}

// runOutcome shells `kido runs --json <run-id>` and returns the parsed
// outcome.
func (h *harness) runOutcome(runID string) string {
	h.t.Helper()
	out := h.runKido("alpha", runID+"-show.out", "runs", "--json", runID)
	var info runInfo
	// runKido's own output also carries "rc=0" on its own line, which is
	// not part of the JSON kido runs printed.
	line := strings.SplitN(out, "\n", 2)[0]
	if err := json.Unmarshal([]byte(line), &info); err != nil {
		h.t.Fatalf("kido runs --json %s: %v (%q)", runID, err, out)
	}
	return info.Outcome
}

// TestRunRecordSurvivesReapAsDied spawns a child that never reports an
// outcome for itself and is killed outright - the SIGKILL / OOM case
// docs/subagents-plan.md's Phase 8 section calls Died - and checks that
// the run record is still readable, with that outcome, once the sidebar's
// own sweep has collected its window. This is the point of the whole
// design: the outcome must survive the window closing, not just the pane
// dying.
func TestRunRecordSurvivesReapAsDied(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	runID, windowID := h.spawnRun("died-e2e", "exec sleep 300")
	paneID := h.in("list-panes", "-t", windowID, "-F", "#{pane_id}")
	h.killPane(paneID)

	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("the sidebar's sweep to close window %s", windowID))

	if got := h.runOutcome(runID); got != "died" {
		t.Errorf("run %s outcome = %q, want %q", runID, got, "died")
	}
}

// TestRunRecordSurvivesReapAsCompleted is the same shape, but the child
// reports itself before exiting - standing in for pi's own
// sendCompletionNotice calling `kido run-outcome`, which the e2e suite
// cannot exercise directly since it cannot host the TypeScript extension.
// The recorded outcome must win over the sweep's own Died guess, which
// would otherwise fire for exactly the same dead, marked window.
func TestRunRecordSurvivesReapAsCompleted(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	// The short sleep before reporting is not decoration: tmux.NewWindow
	// sets remain-on-exit in a second tmux invocation, and a command that
	// exits before it lands loses its window outright - measured at 20 out
	// of 20 for /bin/true (see NewWindow's own doc, which is where that gap
	// and the reasons for leaving it are recorded). Without the sleep this
	// test would be asserting against a window that had already vanished.
	script := fmt.Sprintf(`sleep 0.3; %s run-outcome --result completed -- "$KIDO_AGENT_RUN_ID"`, kidoBin)
	runID, windowID := h.spawnRun("done-e2e", script)

	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("the sidebar's sweep to close window %s once the child has exited", windowID))

	if got := h.runOutcome(runID); got != "completed" {
		t.Errorf("run %s outcome = %q, want %q (the sweep's own Died guess must not win the race)", runID, got, "completed")
	}
}

// TestStopRecordsStoppedOutcome checks that `kido stop`, ending a wedged
// child by escalating to a window kill, records the run's outcome as
// Stopped rather than leaving the sweep to call it Died a moment later -
// the two would otherwise be indistinguishable once the window is gone.
func TestStopRecordsStoppedOutcome(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	runID, windowID := h.spawnRun("wedged-run-e2e", "exec sleep 300")
	// A real inbox that never actually shuts the session down, standing in
	// for a wedged pi extension - the same trick control_test.go's
	// wedgedChild uses, but reporting under the run's own id (target.ID
	// must equal the run id for stopCmd's outcome write to land anywhere).
	paneID := h.in("list-panes", "-t", windowID, "-F", "#{pane_id}")
	in := testutil.StartInbox(h.t, "ok\n")
	h.agentStatus(runID, paneID, "pi", "idle", "--instance", runID+"-inst", "--inbox", in.Path, "--protocol", "1")

	out := h.runKido("alpha", "stop.out", "stop", runID)
	if !strings.Contains(out, "killed") {
		t.Fatalf("kido stop output = %q, want the escalation to kill the wedged child's window", out)
	}
	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("window %s to be killed by the stop escalation", windowID))

	if got := h.runOutcome(runID); got != "stopped" {
		t.Errorf("run %s outcome = %q, want %q", runID, got, "stopped")
	}
}
