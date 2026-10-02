package e2e

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// wrapperPID finds the wrapper by run id on its own command line, not
// by reading the run's meta file, which would ask kido what it believes
// rather than what is running.
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

// killWrapper SIGKILLs a run's wrapper: an ending it cannot report, so
// its outcome and notice are simply never written.
func (h *harness) killWrapper(runID string) {
	h.t.Helper()
	pid := h.wrapperPID(runID)
	if err := syscall.Kill(pid, syscall.SIGKILL); err != nil {
		h.t.Fatal(err)
	}
	h.waitFor(func() bool { return syscall.Kill(pid, 0) == syscall.ESRCH }, settle,
		msgf("the wrapper of run %s (pid %d) to exit", runID, pid))
}

// hideSidebar removes the sidebar sweeper so a test about `kido reap` is
// not decided by the other one racing it.
func (h *harness) hideSidebar() {
	h.t.Helper()
	h.in("set", "-g", "side-status", "off")
	h.waitFor(func() bool { return !h.sidebarVisible() }, settle, msgf("the sidebar to go away"))
}

// A SIGKILLed wrapper cannot report its own ending, so a backstop must
// (design.md §6). The sidebar sweeper is left running alongside the
// explicit `kido reap` here, so two real observers race for one ending;
// exactly one notice is the assertion.
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

// Stop records its intent before TERM, so the wrapper's signal error
// cannot win; the wrapper forwards TERM and one ending reaches the parent.
// Sidebar hidden so the stop and wrapper are the only observers.
func TestStopBashRunNotifiesOnce(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	in := h.asyncParent("alpha", "parent-stop-e2e")

	runID := h.asyncBash("stopme", "sleep", "60")
	h.hideSidebar()

	out := h.runKido("alpha", "stop.out", "tool", "stop_run", "--force", "--", "stopme")
	if !strings.Contains(out, "rc=0") {
		t.Fatalf("kido tool stop_run output = %q, want a clean exit", out)
	}

	h.waitFor(func() bool { return len(in.Received()) > 0 }, 2*time.Second,
		msgf("the parent to be told the run was stopped"))
	got := in.Received()[0]
	if !strings.Contains(got, "stopme") {
		t.Errorf("notice = %q, want it to name the run", got)
	}
	h.stableCount(in, 1, "a stop is one ending, whichever observer reports it")

	info := h.waitOutcome(runID)
	if info.Outcome != "stopped" || info.OutcomeText != "stopped by its parent" {
		t.Errorf("kido runs reports %q/%q, want stopped by its parent", info.Outcome, info.OutcomeText)
	}
}

// Deterministic half of the test above: wrapper already gone, so the
// stop's own report is the only one that can arrive.
func TestStopSpeaksForAWrapperThatCannot(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	in := h.asyncParent("alpha", "parent-stopdead-e2e")

	runID := h.asyncBash("zombie", "sleep", "60")
	h.hideSidebar() // before the kill, so nothing else sweeps the corpse first
	h.killWrapper(runID)

	out := h.runKido("alpha", "stopdead.out", "tool", "stop_run", "--force", "--", "zombie")
	if !strings.Contains(out, "rc=0") {
		t.Fatalf("kido tool stop_run output = %q, want a clean exit", out)
	}

	h.waitFor(func() bool { return len(in.Received()) > 0 }, 2*time.Second,
		msgf("the stop to report an ending its wrapper could not"))
	if got := in.Received()[0]; !strings.Contains(got, "zombie") || !strings.Contains(got, "stopped") {
		t.Errorf("notice = %q, want it to say the run was stopped", got)
	}
	h.stableCount(in, 1, "one ending, one notice")

	info := h.waitOutcome(runID)
	if info.Outcome != "stopped" || info.OutcomeText != "stopped by its parent" {
		t.Errorf("kido runs reports %q/%q, want stopped with the stop naming itself", info.Outcome, info.OutcomeText)
	}
}

// Agent twin of TestKilledWrapperIsReportedByWhoeverFindsIt: the incident
// this rule comes from was a child closed mid-work whose parent learnt
// nothing, because the sweep recorded `died` silently. The child here is
// a plain sleep, never reaching notify_parent; sidebar and explicit reap
// again race for the one notice.
func TestReapedAgentRunTellsItsParentNobodyReported(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	in := h.asyncParent("alpha", "parent-silent-e2e")

	taskFile := filepath.Join(h.dir, "silent-task.txt")
	if err := os.WriteFile(taskFile, []byte("do the thing"), 0o644); err != nil {
		t.Fatal(err)
	}
	outFile := filepath.Join(h.dir, "spawn-silent.out")
	h.runSpawn(outFile, filepath.Join(h.dir, "silent.env"),
		"--parent-pid", "424242",
		"--parent-session", "parent-silent-e2e",
		"--name", "silent-e2e",
		"--task-file", taskFile,
	)
	fields := strings.Fields(strings.TrimSpace(h.waitFileNonEmpty(outFile)))
	if len(fields) != 3 {
		t.Fatalf("kido tool spawn_subagent printed %q, want \"<window id> <pane id> <run id>\"", fields)
	}
	paneID, runID := fields[1], fields[2]

	h.stableCount(in, 0, "a child still working has no ending to report")
	h.killPane(paneID)

	// The linger the harness runs with is 1s; rule 1 leaves a dead window
	// alone until it has passed.
	time.Sleep(1200 * time.Millisecond)
	if out := h.runKido("alpha", "reap-silent.out", "reap"); !strings.Contains(out, "rc=0") {
		t.Fatalf("kido reap output = %q, want a clean exit", out)
	}

	h.waitFor(func() bool { return len(in.Received()) > 0 }, 2*time.Second,
		msgf("the parent to be told about a child that ended with no outcome of its own"))
	got := in.Received()[0]
	for _, want := range []string{`"kind":"notice"`, "silent-e2e", "without recording an outcome", "died", runID} {
		if !strings.Contains(got, want) {
			t.Errorf("notice = %q, want it to carry %q", got, want)
		}
	}

	h.runKido("alpha", "reap-silent-2.out", "reap")
	h.stableCount(in, 1, "one ending, one notice, however many observers find it")
}
