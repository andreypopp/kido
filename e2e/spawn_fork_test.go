package e2e

import (
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

// TestSpawnForkCarriesTheForkOntoThePiCommandLine: a forked child is
// `pi --fork <the caller's session> --session-id <run id>`, and both
// halves have to be there - the fork is the context the child was spawned
// for, and the run id is what its own extension proves its identity with
// (pi/kido-agents.ts's ownRunID). The unit test pins the argv kido builds;
// this one reads it back via startCommand, exactly as
// TestSpawnResumeCarriesToolsOntoThePiCommandLine does.
//
// The flags are only spelled onto the line when the command is literally
// `pi`, so this spawn names none - which leaves the pane's fate to whether
// that bare name resolves on the machine running the suite. Hence the fake
// pi on this server's PATH alone (the race in internal/tmux/tmux.go: a
// pane that exits first loses its window before remain-on-exit is set).
func TestSpawnForkCarriesTheForkOntoThePiCommandLine(t *testing.T) {
	t.Parallel()
	h := startPathPrefix(t, "alpha", piBinDir)
	h.liveParent("alpha", "root-e2e")

	outFile := filepath.Join(h.dir, "fork.out")
	h.sendLiteral(fmt.Sprintf(
		"%s spawn_subagent --parent-pid 1 --parent-session root-e2e --name forked-e2e "+
			"--task-file %s --fork caller-session-e2e > %s 2>&1",
		kidoBin, h.writeTaskFile("forked-e2e"), outFile))
	h.sendKeys("Enter")
	fields := strings.Fields(strings.TrimSpace(h.waitFileNonEmpty(outFile)))
	if len(fields) != 3 {
		t.Fatalf("kido spawn_subagent --fork printed %q, want \"<window id> <pane id> <run id>\"", fields)
	}
	windowID, runID := fields[0], fields[2]
	t.Cleanup(func() { h.in("kill-window", "-t", windowID) })

	started := h.startCommand(windowID)
	if !strings.Contains(started, "--fork caller-session-e2e") {
		t.Errorf("forked pane's command = %q, want it to fork the session kido was given", started)
	}
	if !strings.Contains(started, "--session-id "+runID) {
		t.Errorf("forked pane's command = %q, want the run id as the child's own session id, which is what its identity proof reads", started)
	}
}
