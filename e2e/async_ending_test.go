package e2e

import (
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// wrapperPID finds the `kido async-run` process of runID by the run id
// on its own command line, which is how anything outside kido would have
// to find it. Reading the run's meta file would ask kido what it
// believes instead of what is running.
func (h *harness) wrapperPID(runID string) int {
	h.t.Helper()
	listing := h.in("list-panes", "-a", "-F", "#{pane_pid} #{pane_start_command}")
	for _, line := range strings.Split(listing, "\n") {
		if !strings.Contains(line, "async-run") || !strings.Contains(line, runID) {
			continue
		}
		pid, err := strconv.Atoi(strings.Fields(line)[0])
		if err != nil {
			h.t.Fatal(err)
		}
		return pid
	}
	h.t.Fatalf("no pane is running `kido async-run` for run %s:\n%s", runID, listing)
	return 0
}

// killWrapper SIGKILLs a run's wrapper and waits for it to go: the one
// ending the wrapper cannot report, since a SIGKILL is not a signal it
// can handle. Everything it would have said - the outcome, the notice -
// is simply never written.
func (h *harness) killWrapper(runID string) {
	h.t.Helper()
	pid := h.wrapperPID(runID)
	if err := syscall.Kill(pid, syscall.SIGKILL); err != nil {
		h.t.Fatal(err)
	}
	h.waitFor(func() bool { return syscall.Kill(pid, 0) == syscall.ESRCH }, settle,
		msgf("the wrapper of run %s (pid %d) to exit", runID, pid))
}

// hideSidebar takes the side column away and waits for it to go, so a
// test about one sweeper is not decided by another. The sweep behind the
// sidebar and the one `kido reap` runs are the same code reading the same
// state directory.
func (h *harness) hideSidebar() {
	h.t.Helper()
	h.in("set", "-g", "side-status", "off")
	h.waitFor(func() bool { return !h.sidebarVisible() }, settle, msgf("the sidebar to go away"))
}

// TestKilledWrapperIsReportedByWhoeverFindsIt is the invariant §6 of the
// async_bash design is built on, end to end and in its hardest form: the
// wrapper reports before it exits, so it covers every ending it lives to
// see, and a SIGKILL is precisely an ending it does not. Without a
// backstop the parent waits forever on a build that has already stopped
// existing - and with a careless one it is told twice and acts twice.
//
// Nothing is hidden here: the session's own sidebar is sweeping
// throughout and `kido reap` is typed over the top of it, so two real
// observers race for one ending and the outcome write is what settles
// which of them speaks. Exactly one notice is the whole assertion, and
// it is watched over a span, because one notice and the first of two are
// identical at any instant.
func TestKilledWrapperIsReportedByWhoeverFindsIt(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	in := h.asyncParent("alpha", "parent-doomed-e2e")

	runID := h.asyncBash("doomed", "sleep", "60")
	h.stableCount(in, 0, "a command still running has no ending to report")
	h.killWrapper(runID)

	// The linger the harness runs with is 1s; rule 1 leaves a dead window
	// alone until it has passed.
	time.Sleep(1200 * time.Millisecond)
	if out := h.runKido("alpha", "reap-doomed.out", "reap"); !strings.Contains(out, "rc=0") {
		t.Fatalf("kido reap output = %q, want a clean exit", out)
	}

	h.waitFor(func() bool { return len(in.Received()) > 0 }, 2*time.Second,
		msgf("the parent to be told about a run whose wrapper was killed"))
	got := in.Received()[0]
	for _, want := range []string{`"kind":"notice"`, "doomed", "failed", runID} {
		if !strings.Contains(got, want) {
			t.Errorf("notice = %q, want it to carry %q", got, want)
		}
	}

	// A second reap, and a span: neither the command nor the sidebar that
	// is still running may tell the story again.
	h.runKido("alpha", "reap-doomed-2.out", "reap")
	h.stableCount(in, 1, "one ending, one notice, however many observers find it")

	info := h.waitOutcome(runID)
	if info.Outcome != "failed" {
		t.Errorf("kido runs reports outcome %q, want failed", info.Outcome)
	}
}

// TestStopBashRunNotifiesOnce is the deliberate ending, which is an
// ending like any other: whoever gets to it first speaks, and only one
// of them does. The wrapper is alive and forwards the signal, so it
// normally reports for itself with its own exit status; the stop's own
// report is the backstop for when it does not, and which one ran is
// visible in the outcome text rather than being left to guess at.
//
// The sidebar is hidden so the two paths under test are the only
// observers, and --force is required exactly as it is for any target
// with no inbox to ask nicely over.
func TestStopBashRunNotifiesOnce(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	in := h.asyncParent("alpha", "parent-stop-e2e")

	runID := h.asyncBash("stopme", "sleep", "60")
	h.hideSidebar()

	out := h.runKido("alpha", "stop.out", "stop_subagent", "--force", "--", "stopme")
	if !strings.Contains(out, "rc=0") {
		t.Fatalf("kido stop_subagent output = %q, want a clean exit", out)
	}

	h.waitFor(func() bool { return len(in.Received()) > 0 }, 2*time.Second,
		msgf("the parent to be told the run was stopped"))
	got := in.Received()[0]
	if !strings.Contains(got, "stopme") {
		t.Errorf("notice = %q, want it to name the run", got)
	}
	h.stableCount(in, 1, "a stop is one ending, whichever observer reports it")

	// Either observer may have got there first; both are correct, and the
	// text says which, which is the property being pinned.
	info := h.waitOutcome(runID)
	switch {
	case info.Outcome == "failed" && strings.Contains(info.OutcomeText, "terminated"):
		t.Logf("the wrapper reported the stop itself: %q", info.OutcomeText)
	case info.Outcome == "stopped" && strings.Contains(info.OutcomeText, "stop_subagent"):
		t.Logf("the stop spoke for a wrapper that did not report: %q", info.OutcomeText)
	default:
		t.Errorf("kido runs reports %q/%q, want either the wrapper's own ending or the stop's, each saying which it is",
			info.Outcome, info.OutcomeText)
	}
}

// TestStopSpeaksForAWrapperThatCannot is the deterministic half of the
// test above: with the wrapper already gone there is nobody who could
// report, so the stop's own story is the only one that can arrive - and
// it must, rather than the run being left recorded as running forever.
// The grace is skipped outright here, since waiting it out would only
// delay a notice nobody else was ever going to send.
func TestStopSpeaksForAWrapperThatCannot(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	in := h.asyncParent("alpha", "parent-stopdead-e2e")

	runID := h.asyncBash("zombie", "sleep", "60")
	// Before the wrapper is killed, so nothing sweeps the corpse and wins
	// the outcome the stop under test is meant to write.
	h.hideSidebar()
	h.killWrapper(runID)

	out := h.runKido("alpha", "stopdead.out", "stop_subagent", "--force", "--", "zombie")
	if !strings.Contains(out, "rc=0") {
		t.Fatalf("kido stop_subagent output = %q, want a clean exit", out)
	}

	h.waitFor(func() bool { return len(in.Received()) > 0 }, 2*time.Second,
		msgf("the stop to report an ending its wrapper could not"))
	if got := in.Received()[0]; !strings.Contains(got, "zombie") || !strings.Contains(got, "stopped") {
		t.Errorf("notice = %q, want it to say the run was stopped", got)
	}
	h.stableCount(in, 1, "one ending, one notice")

	info := h.waitOutcome(runID)
	if info.Outcome != "stopped" || !strings.Contains(info.OutcomeText, "stop_subagent") {
		t.Errorf("kido runs reports %q/%q, want stopped with the stop naming itself", info.Outcome, info.OutcomeText)
	}
}
