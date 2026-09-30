package e2e

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeFakeListModelsPi answers `pi --list-models` with a fixed two-row
// table matching the shape Spawn_subagent.validate_model parses, and exits nonzero for
// anything else - only to test the model gate refusing before any
// window is created.
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

// A bare alias like "sonnet" - what a bare `pi --model sonnet` silently
// matches no provider for, runs no turn, and exits 0 (the bug report
// this fixes) - must be refused before any window is created.
func TestSpawnRefusesModelRejectedByPi(t *testing.T) {
	t.Parallel()
	piDir := filepath.Join(t.TempDir(), "model-pi-bin")
	writeFakeListModelsPi(t, piDir)
	h := startPathPrefix(t, "alpha", piDir)

	h.liveParent("alpha", "model-e2e-parent")
	// PATH is set on the command itself, not relied on from the pane's own
	// login shell (macOS path_helper puts the machine's real pi first, the
	// trap AGENTS.md describes for the shims): the gate runs `pi` from
	// kido's own environment.
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

// A child ending itself with no turn ever run (`kido run-outcome
// --unreported`, what share/pi/kido-agents.ts's idle self-exit calls) must
// save its own pane's screen before it exits, not leave that to a sweep
// that may never run before the window closes - `kido close-run` never
// captures a screen at all. The window is kept alive (`sleep 300`) so
// the screen file existing right after run-outcome returns is proof the
// capture happened at self-report time.
func TestRunOutcomeCapturesScreenBeforeWindowCloses(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	const marker = "KIDO-E2E-NO-TURN-MARKER-9f3c"
	const noTurnText = "no turn ever ran: the task was delivered and the session never started work on it"
	// spawnRun wraps the script in single quotes (shellQuote), so the
	// detail text needs only its own double quotes, not a second layer.
	// The sleep before run-outcome is not decoration: kido spawn_subagent
	// writes meta.json only after Tmux.Exec.new_window returns, so calling
	// run-outcome immediately could win the race against that file existing.
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
