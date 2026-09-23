package e2e

import (
	"strings"
	"testing"
	"time"

	"kido/internal/testutil"
)

// wedgedChild sets up a window in session that looks to kido exactly like
// a live pi subagent with an inbox: a real long-running pane, and a state
// record (via h.agentStatus, run out of band so its pid is this test
// binary's own and stays alive for the whole test - liveParent,
// reap_test.go, is the same trick) naming a real unix socket that
// answers "ok\n" to anything written to it and otherwise does nothing -
// standing in for a pi extension that received the request but never
// acted on it, wedged the way a real one was once observed to be for
// hours after a laptop slept and its provider connection died.
func (h *harness) wedgedChild(session, sessionID string) (paneID, windowID string) {
	h.t.Helper()
	paneID = h.newWindow(session, "", "sh", "-c", "exec sleep 300")
	h.waitPaneCommand(paneID, "sleep")
	windowID = h.windowID(paneID)

	in := testutil.StartInbox(h.t, "ok\n")
	h.agentStatus(sessionID, paneID, "pi", "idle",
		"--instance", sessionID+"-inst", "--inbox", in.Path, "--protocol", "1")
	return paneID, windowID
}

// TestStopKillsAWedgedChildAfterEscalation drives `kido stop_subagent` against a
// target that acknowledges the request over its inbox but never actually
// goes: exactly the case stopCmd's escalation exists for (see
// cmd/kido/control.go). The harness sets KIDO_STOP_ESCALATION_MS to 300ms
// for the whole suite, the same way it shortens KIDO_LINGER_SECONDS.
func TestStopKillsAWedgedChildAfterEscalation(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	_, windowID := h.wedgedChild("alpha", "wedged-e2e")

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

	paneID, windowID := h.wedgedChild("alpha", "healthy-e2e")

	go func() {
		time.Sleep(60 * time.Millisecond)
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
