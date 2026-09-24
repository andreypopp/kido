package e2e

import (
	"strings"
	"testing"
	"time"

	"kido/internal/testutil"
)

// wedgedChild is agentWithInbox (harness_test.go) read as one particular
// thing: an inbox that answers "ok" to anything and then does nothing is
// a pi extension that received the request but never acted on it, wedged
// the way a real one was once observed to be for hours after a laptop
// slept and its provider connection died. The inbox is returned too: a
// caller that needs to know the target actually got the stop request -
// not merely that stop_subagent's own window has had time to start - has
// nowhere else to look.
func (h *harness) wedgedChild(session, sessionID string) (paneID, windowID string, in *testutil.Inbox) {
	h.t.Helper()
	in, paneID = h.agentWithInbox(session, sessionID)
	return paneID, h.windowID(paneID), in
}

// TestStopKillsAWedgedChildAfterEscalation drives `kido stop_subagent` against a
// target that acknowledges the request over its inbox but never actually
// goes: exactly the case stopCmd's escalation exists for (see
// cmd/kido/control.go). The harness sets KIDO_STOP_ESCALATION_MS to 300ms
// for the whole suite, the same way it shortens KIDO_LINGER_SECONDS.
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

// TestStopDoesNotKillAHealthyChild is the negative control: a target
// whose record goes away shortly after being asked to stop - standing in
// for pi's own session_shutdown handler actually removing it, the
// teardown phase 6 built - must never have its window killed.
func TestStopDoesNotKillAHealthyChild(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	paneID, windowID, in := h.wedgedChild("alpha", "healthy-e2e")

	// The record must not disappear until the stop request has actually
	// reached the target: stop_subagent runs in a freshly created window
	// (runKido), and that window taking longer to start than some fixed
	// guess to remove the record first is exactly how this test used to
	// fail ("no agent session matches") before controlTarget ever got to
	// send anything. in.Received() is the one place delivery can be
	// observed from outside the target, so it is what gates the removal.
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
