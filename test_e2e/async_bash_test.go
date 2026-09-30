package e2e

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// asyncParent gives the session's own pane a real inbox and a recorded
// agent, so `kido async_bash` typed there has a parent to resolve and a
// delivery - or its absence - is observable from outside.
func (h *harness) asyncParent(session, id string) *inbox {
	h.t.Helper()
	in := startInbox(h.t, "ok\n")
	pane := h.in("display-message", "-p", "-t", session+":", "#{pane_id}")
	h.agentStatus(id, pane, "pi", "idle",
		"--inbox", in.Path)
	return in
}

func (h *harness) asyncBash(name string, command ...string) string {
	h.t.Helper()
	return h.asyncBashWith(nil, name, command...)
}

func (h *harness) asyncBashWith(flags []string, name string, command ...string) string {
	h.t.Helper()
	_, _, runID := h.asyncBashIDs(flags, name, command...)
	return runID
}

func (h *harness) asyncBashIDs(flags []string, name string, command ...string) (windowID, paneID, runID string) {
	h.t.Helper()
	outFile := filepath.Join(h.dir, "async-"+name+".out")
	quoted := make([]string, len(command))
	for i, c := range command {
		quoted[i] = shellQuote(c)
	}
	h.sendLiteral(fmt.Sprintf("%s async_bash --name %s %s -- %s > %s 2>&1; echo rc=$? >> %s",
		kidoBin, name, strings.Join(flags, " "), strings.Join(quoted, " "), outFile, outFile))
	h.sendKeys("Enter")
	out := h.waitFileContains(outFile, "rc=")
	fields := strings.Fields(out)
	if len(fields) < 3 || !strings.Contains(out, "rc=0") {
		h.t.Fatalf("kido async_bash printed %q, want \"<window id> <pane id> <run id>\" and rc=0", out)
	}
	return fields[0], fields[1], fields[2]
}

// stableCount watches over a span, not an instant: "nothing yet" and
// "nothing ever" look the same otherwise.
func (h *harness) stableCount(in *inbox, want int, why string) {
	h.t.Helper()
	deadline := time.Now().Add(1500 * time.Millisecond)
	for time.Now().Before(deadline) {
		if got := in.Received(); len(got) != want {
			h.t.Fatalf("%s: inbox holds %d envelopes, want %d: %q", why, len(got), want, got)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func (h *harness) waitOutcome(runID string) runInfo {
	h.t.Helper()
	var info runInfo
	h.waitFor(func() bool {
		info = h.runInfo(runID)
		return info.Outcome != "running"
	}, settle, msgf("run %s to record an outcome (is %q)", runID, info.Outcome))
	return info
}

func (h *harness) runInfo(runID string) runInfo {
	h.t.Helper()
	out := h.runKido("alpha", runID+"-show.out", "runs", "--json", runID)
	var info runInfo
	// runKido's script appends its own "rc=0" line after the JSON.
	if err := json.Unmarshal([]byte(strings.SplitN(out, "\n", 2)[0]), &info); err != nil {
		h.t.Fatalf("kido runs --json %s: %v (%q)", runID, err, out)
	}
	return info
}

// End to end: a command run in its own window, its output kept, its
// ending recorded, and its parent told once by the wrapper itself with
// nothing polling. A bash run writes no state record, so the notice must
// name the run by "build" in the text, not by any recorded identity.
func TestAsyncBashNotifiesItsParentOnce(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	in := h.asyncParent("alpha", "parent-async-e2e")

	t0 := time.Now()
	runID := h.asyncBash("build", "/bin/sh", "-c", "echo out; echo err >&2; exit 3")

	h.waitFor(func() bool { return len(in.Received()) > 0 }, settle,
		msgf("the parent's inbox to receive the run's completion notice"))
	elapsed := time.Since(t0)
	t.Logf("measured async_bash completion -> parent-inbox latency: %s", elapsed)
	// Loose relative to settle: bounding a push-based delivery, not the
	// cost of typing a command line and starting two processes.
	if elapsed > 2*time.Second {
		t.Errorf("notice arrived %s after the command was typed, want it pushed on the run's own ending", elapsed)
	}

	got := in.Received()[0]
	for _, want := range []string{`"kind":"notice"`, "build", "exit status 3", "out", "err", runID} {
		if !strings.Contains(got, want) {
			t.Errorf("notice = %q, want it to carry %q", got, want)
		}
	}
	h.stableCount(in, 1, "one run, one notice")

	info := h.waitOutcome(runID)
	if info.Kind != "bash" {
		t.Errorf("kido runs reports kind %q, want \"bash\"", info.Kind)
	}
	if info.Outcome != "failed" || info.OutcomeText != "exit status 3" {
		t.Errorf("kido runs reports outcome %q/%q, want failed/\"exit status 3\"", info.Outcome, info.OutcomeText)
	}

	body := h.waitFileContains(filepath.Join(h.stateDir, "runs", runID, "output"), "err")
	if !strings.Contains(body, "out") {
		t.Errorf("output file = %q, want stdout and stderr both teed into it", body)
	}
}

// remain-on-exit is set by a second call after new-window, so tmux loses
// the race for a command as fast as `true`: the window may vanish. The
// wrapper reports before it exits, so the notice and outcome survive
// regardless; the window itself is deliberately not asserted on.
func TestAsyncBashThatExitsInstantlyStillNotifiesOnce(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	in := h.asyncParent("alpha", "parent-instant-e2e")

	runID := h.asyncBash("instant", "true")
	windows := h.in("list-windows", "-a", "-F", "#{window_name}")

	h.waitFor(func() bool { return len(in.Received()) > 0 }, settle,
		msgf("the notice of a run that exited instantly"))
	if got := in.Received()[0]; !strings.Contains(got, "instant") || !strings.Contains(got, "exit status 0") {
		t.Errorf("notice = %q, want it to name the run and its exit status", got)
	}
	h.stableCount(in, 1, "an instant exit is still one ending")

	info := h.waitOutcome(runID)
	if info.Outcome != "completed" {
		t.Errorf("kido runs reports outcome %q, want completed", info.Outcome)
	}
	// Reported, not asserted: the answer may differ by machine.
	t.Logf("windows just after an instantly-exiting run was created: %q", strings.Fields(windows))
}

// Negative control for the two tests above: a wrapper that notified on
// start, or twice, would pass both without this.
func TestAsyncBashStillRunningSaysNothing(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	in := h.asyncParent("alpha", "parent-quiet-e2e")

	runID := h.asyncBash("slow", "sleep", "30")
	h.stableCount(in, 0, "a command still running has no ending to report")
	if info := h.runInfo(runID); info.Outcome != "running" {
		t.Errorf("kido runs reports outcome %q, want running", info.Outcome)
	}
}

// Run from a pane with no state record - a human's shell, or a run that
// outlives its parent - so there is nobody to notify; the run must still
// finish and record its outcome. The live inbox in the same session
// makes "nobody" checkable: a wrapper resolving some other parent would
// show up there.
func TestAsyncBashWithNoParentStillRecordsItsOutcome(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	in := h.asyncParent("alpha", "parent-unrelated-e2e")

	out := h.runKido("alpha", "noparent.out", "async_bash", "--name", "orphanish", "--", shellQuote("exit 7"))
	fields := strings.Fields(out)
	if len(fields) < 3 {
		t.Fatalf("kido async_bash printed %q, want \"<window id> <pane id> <run id>\"", out)
	}
	runID := fields[2]

	info := h.waitOutcome(runID)
	if info.Outcome != "failed" || info.OutcomeText != "exit status 7" {
		t.Errorf("kido runs reports %q/%q, want failed/\"exit status 7\"", info.Outcome, info.OutcomeText)
	}
	h.stableCount(in, 0, "a run with no parent has nobody to tell")
}
