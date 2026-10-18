package e2e

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// hideSidebar removes the sidebar sweeper so a test about `kido reap` is
// not decided by the other one racing it.
func (h *harness) hideSidebar() {
	h.t.Helper()
	h.in("set", "-g", "side-status", "off")
	h.waitFor(func() bool { return !h.sidebarVisible() }, settle, msgf("the sidebar to go away"))
}

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
		"--name", "silent-e2e",
		"--task-file", taskFile,
	)
	fields := strings.Fields(strings.TrimSpace(h.waitFileNonEmpty(outFile)))
	if len(fields) != 3 {
		t.Fatalf("kido tool spawn_subagent printed %q, want \"<window id> <pane id> <run id>\"", fields)
	}
	paneID, runID := fields[1], fields[2]

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
	for _, want := range []string{`"kind":"notice"`, "silent-e2e", "without recording an outcome", "failed", runID} {
		if !strings.Contains(got, want) {
			t.Errorf("notice = %q, want it to carry %q", got, want)
		}
	}

	h.runKido("alpha", "reap-silent-2.out", "reap")
	h.stableCount(in, 1, "one ending, one notice, however many observers find it")
}
