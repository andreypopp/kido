package e2e

import (
	"strings"
	"testing"
	"time"
)

// wedgedChild's inbox answers "ok" to anything and does nothing else: a
// pi extension that received the request but never acted on it, wedged
// the way a real one was once observed for hours after a laptop slept
// and its provider connection died.
func (h *harness) wedgedChild(session, sessionID string) (paneID, windowID string, in *inbox) {
	h.t.Helper()
	in, paneID = h.agentWithInbox(session, sessionID)
	return paneID, h.windowID(paneID), in
}

// A target that acknowledges the stop over its inbox but never actually
// goes is exactly the case Control.stop's escalation exists for.
func TestStopKillsAWedgedChildAfterEscalation(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	_, windowID, _ := h.wedgedChild("alpha", "wedged-e2e")

	out := h.runKido("alpha", "stop.out", "stop_subagent", "wedged-e2e")
	if !strings.Contains(out, "killed") {
		t.Errorf("kido stop_subagent output = %q, want it to say the window was killed", out)
	}
	if !strings.Contains(out, "rc=0") {
		t.Errorf("kido stop_subagent output = %q, want a successful exit: the escalation itself is not a failure", out)
	}
	h.waitFor(func() bool { return !h.windowExists(windowID) }, settle,
		msgf("window %s to be killed after the escalation timeout", windowID))
}

// Negative control: a target whose record goes away shortly after being
// asked to stop, standing in for pi's session_shutdown handler removing
// it, must never have its window killed.
func TestStopDoesNotKillAHealthyChild(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	paneID, windowID, in := h.wedgedChild("alpha", "healthy-e2e")

	// Removing the record before the stop request actually reaches the
	// target (racing the freshly created window's own startup) used to fail
	// this test with "no agent session matches"; in.Received() gates it.
	go func() {
		deadline := time.Now().Add(settle)
		for len(in.Received()) == 0 && time.Now().Before(deadline) {
			time.Sleep(10 * time.Millisecond)
		}
		h.agentStatus("healthy-e2e", paneID, "pi", "idle", "--remove")
	}()

	out := h.runKido("alpha", "stop.out", "stop_subagent", "healthy-e2e")
	if !strings.Contains(out, "rc=0") {
		t.Fatalf("kido stop_subagent output = %q, want a successful exit", out)
	}
	if strings.Contains(out, "killed") {
		t.Errorf("kido stop_subagent output = %q, want no escalation: the target stopped in time", out)
	}
	h.stays(func() bool { return h.windowExists(windowID) },
		"a healthy child's window must never be killed")
}
