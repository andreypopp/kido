package e2e

import (
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

// asyncBashFields is asyncBash but keeps all three fields, since this
// test needs the pane id to split off of.
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

func countRows(lines []string, sub string) int {
	n := 0
	for _, l := range lines {
		if strings.Contains(l, sub) {
			n++
		}
	}
	return n
}

// A user splitting a running async_bash run's window must see the split
// pane draw as the plain shell it is, not a second copy of the run:
// @kido_run is pane-scoped with no window-scoped fallback, and
// Spawn_subagent.create_run_window never marked the split.
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

	// Wait for the split's own command, not a bare row count, which was
	// already satisfied before the split.
	h.waitFor(func() bool { return hasLine(h.rows(), "sleep") }, settle,
		msgf("the split pane's own row (rows: %q)", h.rows()))

	rows := h.rows()
	if n := countRows(rows, "split-e2e"); n != 1 {
		t.Errorf("after the split: rows = %q, want the run's name exactly once, got %d", rows, n)
	}
}
