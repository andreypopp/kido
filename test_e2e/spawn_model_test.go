package e2e

import (
	"fmt"
	"strings"
	"testing"
)

// A run ending itself with `kido run-outcome` must save its own pane's
// screen before it exits, not leave that to a sweep that may never run
// before the window closes. The window is kept alive (`sleep 300`) so the
// screen file existing right after run-outcome returns is proof the
// capture happened at self-report time.
func TestRunOutcomeCapturesScreenBeforeWindowCloses(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	caller := h.firstPane("alpha")

	const marker = "KIDO-E2E-NO-TURN-MARKER-9f3c"
	const noTurnText = "no turn ever ran: the task was delivered and the session never started work on it"
	script := fmt.Sprintf(`echo %s; sleep 0.3; %s run-outcome --result failed --text "%s" -- "$KIDO_RUN_ID"; sleep 300`,
		marker, kidoBin, noTurnText)
	r := h.startRun(caller, "run", "--name", "no-turn-e2e", "--", "bash", "-c", script)

	h.waitFor(func() bool { return h.runOutcome(r.ID) == "failed" }, settle,
		msgf("run %s to record its own no-turn-ever-ran outcome", r.ID))

	windowID, _, _ := strings.Cut(r.Pane, ".")
	if !h.windowExists(windowID) {
		t.Fatalf("window %s is already gone; the screen capture race this test checks needs it still up", windowID)
	}
	out := h.runKido("alpha", "no-turn-screen.out", "runs", r.ID)
	if !strings.Contains(out, marker) {
		t.Errorf("kido runs %s = %q, want the run's own screen captured before it exited, marker %q included", r.ID, out, marker)
	}
}
