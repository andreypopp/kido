package e2e

import (
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

// asyncBashFields is asyncBash but keeps all three fields kido async_bash
// printed, not just the run id: this test needs the pane id to split off
// of.
func (h *harness) asyncBashFields(name string, command ...string) (windowID, paneID, runID string) {
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
	return fields[0], fields[1], fields[2]
}

// countRows is how many of the sidebar's non-empty lines contain sub.
func countRows(lines []string, sub string) int {
	n := 0
	for _, l := range lines {
		if strings.Contains(l, sub) {
			n++
		}
	}
	return n
}

// TestSidebarShowsASplitBashRunPaneAsAnOrdinaryShell is the live bug this
// change fixes, end to end: a user splits a running async_bash run's
// window, and the split pane must draw as the plain shell it is - not as
// a second copy of the run, which is what a marked window with no
// pane-scoped option to tell its own pane apart from the split drew
// before createRunWindow started setting @kido_subagent_pane.
func TestSidebarShowsASplitBashRunPaneAsAnOrdinaryShell(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.asyncParent("alpha", "parent-split-e2e")

	_, paneID, _ := h.asyncBashFields("split-e2e", "sleep", "300")
	h.waitRow("split-e2e")
	if n := countRows(h.rows(), "split-e2e"); n != 1 {
		t.Fatalf("before the split: %d rows carry the run's name, want 1", n)
	}

	h.in("split-window", "-d", "-t", paneID, "sleep", "250")

	// The split takes a moment to appear as its own row; wait for its own
	// command to show up rather than a bare row count, which was already
	// satisfied before the split (alpha's own pane plus the run's row).
	h.waitFor(func() bool { return hasLine(h.rows(), "sleep") }, settle,
		msgf("the split pane's own row (rows: %q)", h.rows()))

	rows := h.rows()
	if n := countRows(rows, "split-e2e"); n != 1 {
		t.Errorf("after the split: rows = %q, want the run's name exactly once, got %d", rows, n)
	}
}
