package e2e

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"kido/internal/testutil"
)

// asyncParent puts a real inbox on the session's own pane and records an
// agent there, so `kido async_bash` typed into that pane has a parent to
// resolve and the notice has somewhere to land. The inbox is the only
// place a delivery - or the absence of one - can be observed from
// outside, exactly as it is for a spawned child's notice
// (TestSpawnedChildNoticeReachesParentInboxQuickly).
func (h *harness) asyncParent(session, id string) *testutil.Inbox {
	h.t.Helper()
	in := testutil.StartInbox(h.t, "ok\n")
	pane := h.in("display-message", "-p", "-t", session+":", "#{pane_id}")
	h.agentStatus(id, pane, "pi", "idle",
		"--instance", id+"-inst", "--inbox", in.Path, "--protocol", "1")
	return in
}

// asyncBash types `kido async_bash` into the session's own pane - which
// is where a caller with a state record is, and so the only place the
// command can find a parent - and returns the run id it printed.
func (h *harness) asyncBash(name string, command ...string) string {
	h.t.Helper()
	outFile := filepath.Join(h.dir, "async-"+name+".out")
	quoted := make([]string, len(command))
	for i, c := range command {
		quoted[i] = shellQuote(c)
	}
	h.sendLiteral(fmt.Sprintf("%s async_bash --name %s -- %s > %s 2>&1; echo rc=$? >> %s",
		kidoBin, name, strings.Join(quoted, " "), outFile, outFile))
	h.sendKeys("Enter")
	out := h.waitFileContains(outFile, "rc=")
	fields := strings.Fields(out)
	if len(fields) < 3 || !strings.Contains(out, "rc=0") {
		h.t.Fatalf("kido async_bash printed %q, want \"<window id> <pane id> <run id>\" and rc=0", out)
	}
	return fields[2]
}

// stableCount asserts that in holds exactly want envelopes and goes on
// holding exactly that many for a span. "Nothing yet" and "nothing ever"
// are identical at any instant, and so are "one notice" and "the first of
// two": only watching over a span tells them apart.
func (h *harness) stableCount(in *testutil.Inbox, want int, why string) {
	h.t.Helper()
	deadline := time.Now().Add(1500 * time.Millisecond)
	for time.Now().Before(deadline) {
		if got := in.Received(); len(got) != want {
			h.t.Fatalf("%s: inbox holds %d envelopes, want %d: %q", why, len(got), want, got)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// waitOutcome waits until runID has any recorded outcome and returns the
// whole record `kido runs --json` prints.
func (h *harness) waitOutcome(runID string) runInfo {
	h.t.Helper()
	var info runInfo
	h.waitFor(func() bool {
		info = h.runInfo(runID)
		return info.Outcome != "running"
	}, settle, msgf("run %s to record an outcome (is %q)", runID, info.Outcome))
	return info
}

// runInfo shells `kido runs --json <run-id>` in a one-shot window and
// parses the row back.
func (h *harness) runInfo(runID string) runInfo {
	h.t.Helper()
	out := h.runKido("alpha", runID+"-show.out", "runs", "--json", runID)
	var info runInfo
	// runKido's script appends "rc=0" on its own line, which is not part
	// of the JSON kido runs printed.
	if err := json.Unmarshal([]byte(strings.SplitN(out, "\n", 2)[0]), &info); err != nil {
		h.t.Fatalf("kido runs --json %s: %v (%q)", runID, err, out)
	}
	return info
}

// TestAsyncBashNotifiesItsParentOnce is the whole of phase one end to
// end: a command run in a window of its own, its output kept, its ending
// recorded, and its parent told once - by the wrapper itself, with
// nothing polling anything.
//
// The notice must name the run. A bash run writes no state record, so the
// receiving side has nothing to label the sender with and falls through
// to the pane id; "build" is in the text or it is nowhere.
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
	// Loose relative to settle, for the reason
	// TestSpawnedChildNoticeReachesParentInboxQuickly gives: what this
	// bounds is a delivery tied to something interval-shaped, not the cost
	// of typing a command line and starting two processes.
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

	// The notice carries a tail; the file is the source of truth, and has
	// both streams in it.
	body := h.waitFileContains(filepath.Join(h.stateDir, "runs", runID, "output"), "err")
	if !strings.Contains(body, "out") {
		t.Errorf("output file = %q, want stdout and stderr both teed into it", body)
	}
}

// TestAsyncBashThatExitsInstantlyStillNotifiesOnce is the
// remain-on-exit race, which tmux loses every time for a command like
// this one: the option is set by a second call after new-window, and
// `true` is gone before it lands (internal/tmux.NewWindow's own note).
// Under a completion mechanism that reads the dead pane - OSC 133, or
// #{pane_dead_status} - losing the window loses the ending outright.
// Because the wrapper reports before it exits, the race costs the corpse
// on screen and nothing else: the notice and the outcome are both
// already written. The window is deliberately not asserted on; whether it
// survives is tmux's race to win or lose.
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
	// Reported, not asserted: this is the measurement the phase exists to
	// take, and the answer may differ by machine.
	t.Logf("windows just after an instantly-exiting run was created: %q", strings.Fields(windows))
}

// TestAsyncBashStillRunningSaysNothing is the negative control the two
// tests above are unsafe without: a wrapper that notified on start, or
// twice, would satisfy every assertion about a notice arriving. Watched
// over a span, because at any instant a notice that never comes and one
// that has not come yet look the same.
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

// TestAsyncBashWithNoParentStillRecordsItsOutcome pins that the child
// never depends on the parent: run from a pane with no state record -
// a human's shell, and the case a run outlives its parent ends in - there
// is nobody to notify, and the run must still finish on time and record
// what happened. The live inbox in the same session is what makes the
// "nobody" half checkable: a wrapper that resolved some other agent as
// its parent would show up there.
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
