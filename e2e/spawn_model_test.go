package e2e

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeFakeListModelsPi writes a shell script named "pi" in dir that
// answers `pi --list-models` with a fixed two-row table (a header, then
// one row per configured model, matching the shape validateModel parses)
// and exits nonzero for anything else - this fixture exists only to test
// kido spawn_subagent's model gate refusing before any window is ever
// created, so a real pi child is never actually launched in the case it
// covers.
func writeFakeListModelsPi(t *testing.T, dir string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\n" +
		"case \"$*\" in\n" +
		"  *--list-models*)\n" +
		"    printf 'PROVIDER\\tMODEL\\nacme\\tclaude-sonnet-5\\nacme\\tclaude-opus-5\\n'\n" +
		"    exit 0\n" +
		"    ;;\n" +
		"esac\n" +
		"exit 1\n"
	if err := os.WriteFile(filepath.Join(dir, "pi"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
}

// TestSpawnRefusesModelRejectedByPi is the model gate end to end: a bare
// alias like "sonnet" - what a bare `pi --model sonnet` silently matches
// no provider for, runs no turn, and exits 0 (the bug report this fixes)
// - is refused before any window is created, the same shape as
// TestSpawnFabricatedParentIsRefusedUpFront.
func TestSpawnRefusesModelRejectedByPi(t *testing.T) {
	t.Parallel()
	piDir := filepath.Join(t.TempDir(), "model-pi-bin")
	writeFakeListModelsPi(t, piDir)
	h := startPathPrefix(t, "alpha", piDir)

	h.liveParent("alpha", "model-e2e-parent")
	// PATH is set on the command itself: a pane's own PATH is whatever
	// its login shell left, which on macOS is path_helper's order with the
	// machine's real pi ahead of the fake (the trap AGENTS.md describes
	// for the shims), and on CI has no pi at all. The gate runs `pi` from
	// kido's own environment, so that is the one that must name the fake.
	outFile := filepath.Join(h.dir, "model-refused.out")
	h.sendLiteral(fmt.Sprintf("PATH=%s:$PATH %s spawn_subagent --parent-pid 1 --parent-session model-e2e-parent --name model-e2e --task-file %s -- pi --name model-e2e --model sonnet > %s 2>&1; echo rc=$? >> %s",
		shellQuote(piDir), kidoBin, h.writeTaskFile("model-e2e"), outFile, outFile))
	h.sendKeys("Enter")
	var out string
	h.waitFor(func() bool {
		b, err := os.ReadFile(outFile)
		if err != nil || !strings.Contains(string(b), "rc=") {
			return false
		}
		out = string(b)
		return true
	}, settle, msgf("%s to contain an rc= line", outFile))
	if !strings.Contains(out, "acme/{") {
		t.Fatalf("output = %q, want the fake pi's table to have answered, not the machine's own", out)
	}
	if !strings.Contains(out, "rc=1") {
		t.Errorf("kido spawn_subagent with an unconfigured model = %q, want rc=1", out)
	}
	if !strings.Contains(out, "sonnet") || !strings.Contains(out, "claude-sonnet-5") {
		t.Errorf("output = %q, want it to name the model and what pi --list-models configured", out)
	}
	if got := h.in("list-windows", "-a", "-F", "#{window_name}"); strings.Contains(got, "model-e2e") {
		t.Errorf("windows = %q, want no window created for a refused spawn", got)
	}
}

// TestRunOutcomeCapturesScreenBeforeWindowCloses is item 1 of the bug
// report end to end: a child ending itself with no turn ever run
// (`kido run-outcome --unreported`, which is exactly what
// pi/kido-agents.ts's idle self-exit calls) must save its own pane's
// screen before it exits, not leave that to a sweep that may never run
// before the window closes - `kido close-run` never captures a screen at
// all. The window is kept alive (`sleep 300` after the call) so the
// screen file's existence right after run-outcome returns is proof the
// capture happened at self-report time, not at some later sweep.
func TestRunOutcomeCapturesScreenBeforeWindowCloses(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	const marker = "KIDO-E2E-NO-TURN-MARKER-9f3c"
	const noTurnText = "no turn ever ran: the task was delivered and the session never started work on it"
	// spawnRun wraps the whole script in single quotes of its own
	// (shellQuote), so the detail text below needs only its own double
	// quotes to survive that, not a second layer.
	// The short sleep before run-outcome is not decoration: kido spawn_subagent
	// writes meta.json only after tmux.NewWindow has returned, so a script
	// that called run-outcome immediately could win the race against its own
	// meta file existing (see TestRunRecordSurvivesReapAsCompleted's own
	// sleep, for the analogous remain-on-exit race).
	script := fmt.Sprintf(`echo %s; sleep 0.3; %s run-outcome --result failed --unreported --text "%s" -- "$KIDO_AGENT_RUN_ID"; sleep 300`,
		marker, kidoBin, noTurnText)
	runID, windowID := h.spawnRun("no-turn-e2e", script)

	h.waitFor(func() bool { return h.runOutcome(runID) == "failed" }, settle,
		msgf("run %s to record its own no-turn-ever-ran outcome", runID))

	if !h.windowExists(windowID) {
		t.Fatalf("window %s is already gone; the screen capture race this test checks needs it still up", windowID)
	}
	out := h.runKido("alpha", "no-turn-screen.out", "runs", runID)
	if !strings.Contains(out, marker) {
		t.Errorf("kido runs %s = %q, want the child's own screen captured before it exited, marker %q included", runID, out, marker)
	}
}
