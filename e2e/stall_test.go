package e2e

import (
	"encoding/json"
	"strconv"
	"strings"
	"testing"
	"time"
)

// stallAgent is a minimal decode of one `kido agents --json` row - just
// the fields these tests need, not the whole of cmd/kido.AgentInfo.
type stallAgent struct {
	ID      string `json:"id"`
	Pane    string `json:"pane"`
	Status  string `json:"status"`
	Stalled bool   `json:"stalled"`
}

// agentsJSON runs `kido agents --json` in a fresh window of session and
// decodes it. runKido's output file also carries a trailing "rc=" line
// (see its own doc), which is not part of the JSON kido wrote, so only
// the first line is decoded.
func (h *harness) agentsJSON(session string) []stallAgent {
	h.t.Helper()
	out := h.runKido(session, "agents.out", "agents", "--json")
	line, _, _ := strings.Cut(out, "\n")
	var agents []stallAgent
	if err := json.Unmarshal([]byte(line), &agents); err != nil {
		h.t.Fatalf("kido agents --json: %v\n%s", err, out)
	}
	return agents
}

func (h *harness) stalledFor(session, id string) func() bool {
	return func() bool {
		for _, a := range h.agentsJSON(session) {
			if a.ID == id {
				return a.Stalled
			}
		}
		return false
	}
}

// TestAgentsShowsStalledAfterHeartbeatStops is the end-to-end stall case:
// an agent that reports Running once and then goes silent - exactly what
// a wedged pi with no heartbeat looks like from outside, and exactly what
// pi/kido-status.ts's heartbeat exists to prevent for a healthy one. The
// harness shortens KIDO_STALL_THRESHOLD_MS for the whole suite.
func TestAgentsShowsStalledAfterHeartbeatStops(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	paneID := h.newWindow("alpha", "", "sh", "-c", "exec sleep 300")
	h.waitPaneCommand(paneID, "sleep")

	id := "stall-no-heartbeat-e2e"
	h.agentStatus(id, paneID, "pi", "running", "--instance", id+"-inst")

	if h.stalledFor("alpha", id)() {
		t.Fatal("must not be stalled immediately after the first report")
	}
	// Longer than settle: the harness's own KIDO_STALL_THRESHOLD_MS (3s)
	// has to elapse before this can succeed at all.
	h.waitFor(h.stalledFor("alpha", id), 8*time.Second,
		msgf("agent %s to be reported stalled once no further report arrives", id))
}

// TestAgentsDoesNotShowStalledWhileHeartbeatContinues is the negative
// control: an agent that keeps re-reporting Running faster than
// KIDO_STALL_THRESHOLD_MS - standing in for pi's own heartbeat - must
// never be marked stalled, however long it runs.
func TestAgentsDoesNotShowStalledWhileHeartbeatContinues(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	paneID := h.newWindow("alpha", "", "sh", "-c", "exec sleep 300")
	h.waitPaneCommand(paneID, "sleep")

	id := "stall-with-heartbeat-e2e"
	stop := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; ; i++ {
			h.agentStatus(id, paneID, "pi", "running", "--instance", id+"-inst",
				"--activity", "heartbeat "+strconv.Itoa(i))
			select {
			case <-stop:
				return
			case <-time.After(120 * time.Millisecond):
			}
		}
	}()
	defer func() {
		close(stop)
		<-done
	}()

	h.stays(func() bool { return !h.stalledFor("alpha", id)() },
		"an agent whose heartbeat keeps arriving must never be marked stalled")
}
