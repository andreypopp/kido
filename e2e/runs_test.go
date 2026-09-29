package e2e

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// runInfo is lib/runs.ml's info as JSON, just the fields these tests
// read, with the outcome flattened: "running" when there is none.
type runInfo struct {
	ID          string
	Kind        string
	Outcome     string
	OutcomeText string
}

func (r *runInfo) UnmarshalJSON(b []byte) error {
	var raw struct {
		ID      string `json:"id"`
		Kind    string `json:"kind"`
		Outcome *struct {
			Result string `json:"result"`
			Text   string `json:"text"`
		} `json:"outcome"`
	}
	if err := json.Unmarshal(b, &raw); err != nil {
		return err
	}
	*r = runInfo{ID: raw.ID, Kind: raw.Kind, Outcome: "running"}
	if raw.Outcome != nil {
		r.Outcome, r.OutcomeText = raw.Outcome.Result, raw.Outcome.Text
	}
	return nil
}

// spawnRun is runSpawn but lets the caller supply the command's script
// directly: runSpawn's own fixed "env; pwd; sleep" script never exits on
// its own, which every test here needs control over.
func (h *harness) spawnRun(name, script string) (runID, windowID string) {
	h.t.Helper()
	h.liveParent("alpha", "root-e2e")
	outFile := filepath.Join(h.dir, name+".out")
	cmd := fmt.Sprintf("%s spawn_subagent --parent-pid 1 --parent-session root-e2e --name %s --task-file %s -- /bin/sh -c %s > %s 2>&1",
		kidoBin, name, h.writeTaskFile(name), shellQuote(script), outFile)
	h.sendLiteral(cmd)
	h.sendKeys("Enter")
	out := strings.TrimSpace(h.waitFileNonEmpty(outFile))
	fields := strings.Fields(out)
	if len(fields) != 3 {
		h.t.Fatalf("kido spawn_subagent printed %q, want \"<window id> <pane id> <run id>\"", out)
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

func (h *harness) runOutcome(runID string) string {
	h.t.Helper()
	out := h.runKido("alpha", runID+"-show.out", "runs", "--json", runID)
	var info runInfo
	line := strings.SplitN(out, "\n", 2)[0] // drop runKido's own trailing "rc=0" line
	if err := json.Unmarshal([]byte(line), &info); err != nil {
		h.t.Fatalf("kido runs --json %s: %v (%q)", runID, err, out)
	}
	return info.Outcome
}

// A child killed outright (subrun's Died case) must leave a readable run
// record once the sidebar's sweep has collected its window: the outcome
// must survive the window closing, not just the pane dying.
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

// Same shape, but the child reports itself before exiting, standing in
// for pi's sendCompletionNotice (the e2e suite cannot host the
// extension). The recorded outcome must win over the sweep's own Died
// guess for the same dead, marked window.
func TestRunRecordSurvivesReapAsCompleted(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	// The sleep is not decoration: Tmux.Exec.new_window sets remain-on-exit in a
	// second call, and a command exiting before it lands loses its window
	// outright (measured 20/20 for /bin/true; see new_window's own comment).
	script := fmt.Sprintf(`sleep 0.3; %s run-outcome --result completed -- "$KIDO_AGENT_RUN_ID"`, kidoBin)
	runID, windowID := h.spawnRun("done-e2e", script)

	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("the sidebar's sweep to close window %s once the child has exited", windowID))

	if got := h.runOutcome(runID); got != "completed" {
		t.Errorf("run %s outcome = %q, want %q (the sweep's own Died guess must not win the race)", runID, got, "completed")
	}
}

// A child's screen output must survive the sweep collecting its window,
// through `kido runs <id>`, the only way a human would actually see it.
func TestRunScreenCapturedOnReap(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	const marker = "KIDO-E2E-SCREEN-MARKER-4f2a"
	// The sleep is not decoration; see TestRunRecordSurvivesReapAsCompleted.
	script := fmt.Sprintf("echo %s; sleep 0.3", marker)
	runID, windowID := h.spawnRun("screen-e2e", script)

	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("the sidebar's sweep to close window %s once the child has exited", windowID))

	out := h.runKido("alpha", "screen-show.out", "runs", runID)
	if !strings.Contains(out, marker) {
		t.Errorf("kido runs %s = %q, want it to contain the captured marker %q", runID, out, marker)
	}
}

// stop_subagent's escalation kill must record the run's outcome as
// Stopped, not leave the sweep to call it Died a moment later -
// indistinguishable once the window is gone.
func TestStopRecordsStoppedOutcome(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	runID, windowID := h.spawnRun("wedged-run-e2e", "exec sleep 300")
	// A real inbox that never shuts the session down, standing in for a
	// wedged pi extension, reporting under the run's own id (the target's
	// session id must equal the run id for Control.stop's outcome write to land anywhere).
	paneID := h.in("list-panes", "-t", windowID, "-F", "#{pane_id}")
	in := startInbox(h.t, "ok\n")
	h.agentStatus(runID, paneID, "pi", "idle", "--inbox", in.Path)

	out := h.runKido("alpha", "stop.out", "stop_subagent", runID)
	if !strings.Contains(out, "killed") {
		t.Fatalf("kido stop_subagent output = %q, want the escalation to kill the wedged child's window", out)
	}
	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("window %s to be killed by the stop escalation", windowID))

	if got := h.runOutcome(runID); got != "stopped" {
		t.Errorf("run %s outcome = %q, want %q", runID, got, "stopped")
	}
}
