package e2e

import (
	"encoding/json"
	"strconv"
	"strings"
	"testing"
	"time"
)

// stallAgent decodes just the fields these tests need from one
// `kido tool list_runs --json` row, not the whole of List_runs.agent_info.
type stallAgent struct {
	ID      string `json:"id"`
	Pane    string `json:"pane"`
	Status  string `json:"status"`
	Stalled bool   `json:"stalled"`
}

// agentsJSON decodes only the first line: runKido's output file also
// carries a trailing "rc=" line, not part of the JSON kido wrote.
func (h *harness) agentsJSON(session string) []stallAgent {
	h.t.Helper()
	out := h.runKido(session, "agents.out", "tool", "list_runs", "--json")
	line, _, _ := strings.Cut(out, "\n")
	var agents []stallAgent
	if err := json.Unmarshal([]byte(line), &agents); err != nil {
		h.t.Fatalf("kido tool list_runs --json: %v\n%s", err, out)
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

// A pi whose OSC root stays working while its identity heartbeat stops
// must eventually be marked stalled.
func TestAgentsShowsStalledAfterHeartbeatStops(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	paneID := h.newWindow("alpha", "", "sh", "-c", "exec sleep 300")
	h.waitPaneCommand(paneID, "sleep")

	id := "stall-no-heartbeat-e2e"
	h.programStatus(paneID, "state=working:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", paneID, "#{pane_title}"), "π - "))
	h.agentStatus(id, paneID, "pi")

	if h.stalledFor("alpha", id)() {
		t.Fatal("must not be stalled immediately after the first report")
	}
	h.waitFor(h.stalledFor("alpha", id), 8*time.Second, // longer than KIDO_STALL_THRESHOLD_MS (3s)
		msgf("agent %s to be reported stalled once no further report arrives", id))
}

// Negative control: a working pi refreshing its identity faster than
// KIDO_STALL_THRESHOLD_MS must never be marked stalled.
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
			h.programStatus(paneID, "state=working:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", paneID, "#{pane_title}"), "π - "))
			h.agentStatus(id, paneID, "pi", "--activity", "heartbeat "+strconv.Itoa(i))
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

// A Claude Code tool call is a silence with no upper bound: PreToolUse
// fires, and nothing else arrives until the tool returns. A slow Bash -
// a build, an ssh to a distant host - therefore outlived the stall
// threshold while working exactly as intended, and the row showed "!".
// The third leg is the one that matters: once the tool returns, an
// ordinary running session goes back to being judged on the clock, so
// the exemption cannot be hiding the signal altogether.
func TestClaudeInsideALongToolCallIsNotStalled(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.newSession("beta")
	pane := h.claudePane("beta", "✳ Slow tool")

	id := "sess-slow-tool"
	h.hook(id, pane, "PreToolUse", "tool_name", "Bash")

	// Well past KIDO_STALL_THRESHOLD_MS (3s): a session judged on report
	// time alone would have been called stalled several times over.
	time.Sleep(6 * time.Second)
	if h.stalledFor("beta", id)() {
		t.Fatal("a session inside a tool call is stalled, though a tool call reports nothing until it returns")
	}

	h.hook(id, pane, "PostToolUse", "tool_name", "Bash")
	if h.stalledFor("beta", id)() {
		t.Fatal("stalled immediately after the tool returned")
	}
	h.waitFor(h.stalledFor("beta", id), 8*time.Second,
		msgf("agent %s to be stalled once no tool is running and no report arrives", id))
}
