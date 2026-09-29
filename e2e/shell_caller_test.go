package e2e

import (
	"fmt"
	"path/filepath"
	"strings"
	"testing"

	"kido/internal/testutil"
)

// The human-as-caller path, end to end. A bare shell is, to kido, a pane
// with no state record (docs/design-subagents.md, "A human at a shell"):
// a window the harness opens and never registers an agent in *is* a
// record-less caller, real rather than constructed as a unit test must.

// pipeKido is runKido (reap_test.go) for the commands reading their text
// from stdin, which is every send. The pane has no agent record, which
// is the point.
func (h *harness) pipeKido(session, outName, input string, args ...string) string {
	h.t.Helper()
	outFile := filepath.Join(h.dir, outName)
	script := fmt.Sprintf("printf %s | %s %s > %s 2>&1; echo rc=$? >> %s",
		shellQuote(input), kidoBin, strings.Join(args, " "), outFile, outFile)
	h.newWindow(session, "", "sh", "-c", script)
	return h.waitFileContains(outFile, "rc=")
}

// The bug was never "the reply is lost", it was that a turn of
// somebody's attention was spent on a question that could never be
// answered - so the assertions that matter are about the target, not
// about what the caller was told.
//
// Measured before the fix: `echo hi | kido ask_agent --id t1 -- <agent>`
// printed "delivered to <agent> by inbox", and the target, on trying to
// answer, got "no agent session matches %47".
func TestAskFromAShellRefusesAndLeavesTheTargetUndisturbed(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	in, paneID := h.agentWithInbox("alpha", "ask-target-e2e")

	const question = "did you finish the migration?"
	out := h.pipeKido("alpha", "ask.out", question,
		"ask_agent", "--id", "t1", "--", "ask-target-e2e")

	if !strings.Contains(out, "rc=1") {
		t.Errorf("kido ask_agent output = %q, want rc=1: a caller with no inbox cannot be answered", out)
	}
	if !strings.Contains(out, "message_agent") {
		t.Errorf("kido ask_agent output = %q, want it to point at kido message_agent", out)
	}
	// stays, not a single reading: "nothing has been delivered yet" and
	// "nothing will be" look identical at any one instant.
	h.stays(func() bool { return len(in.Received()) == 0 },
		"the target's inbox received something: an unanswerable question must not interrupt anyone")
	if got := h.paneText(paneID); strings.Contains(got, question) {
		t.Errorf("target pane %s was typed into: %q; an ask never falls back to a paste either", paneID, got)
	}
}

// Positive control the refusal above needs: without it, both tests would
// pass on a kido where everything from a shell was broken.
func TestMessageFromAShellReachesTheAgent(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	in, _ := h.agentWithInbox("alpha", "msg-target-e2e")

	if out := h.runKido("alpha", "list.out", "list_agents", "--json"); !strings.Contains(out, "msg-target-e2e") {
		t.Errorf("kido list_agents from a shell = %q, want it to name the registered agent", out)
	}

	out := h.pipeKido("alpha", "msg.out", "the build is green",
		"message_agent", "--", "msg-target-e2e")
	if !strings.Contains(out, "rc=0") {
		t.Fatalf("kido message_agent from a shell = %q, want rc=0", out)
	}
	if !strings.Contains(out, "delivered") {
		t.Errorf("kido message_agent output = %q, want it to report the delivery", out)
	}
	// A v1 envelope, not raw text, since the target advertised the
	// protocol; From names only a pane, no session - nothing else a
	// record-less sender has to give.
	h.waitEnvelope(in, `"kind":"message"`, "the build is green", `"session":""`)
}

// waitEnvelope waits until one payload on in contains every one of subs.
// Unlike waitInbox's exact-string compare (prompt_test.go, for the v0
// raw-text path), targets here advertise protocol 1 and get a JSON envelope.
func (h *harness) waitEnvelope(in *testutil.Inbox, subs ...string) {
	h.t.Helper()
	h.waitFor(func() bool {
		for _, got := range in.Received() {
			if matchesAll(got, subs) {
				return true
			}
		}
		return false
	}, settle, msgf("an envelope matching %q to arrive (has %q)", subs, in.Received()))
}

func matchesAll(s string, subs []string) bool {
	for _, sub := range subs {
		if !strings.Contains(s, sub) {
			return false
		}
	}
	return true
}

// `_subagent` tools reach the caller's own descendants, checked by
// descendantTarget (cmd/kido/control.go), which begins by looking the
// caller up: a caller with no record is not an agent, so it is not held
// to a rule about which agents it may act on. Deliberate - the guard is
// a boundary between agents, and a human is not one - and a test is what
// keeps it from being "re-fixed" as a hole.
func TestSteerFromAShellIsNotHeldToTheDescendantRule(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	// Names a parent this caller could not possibly be, so the descendant
	// rule would refuse it outright if it applied.
	in, paneID := h.agentWithInbox("alpha", "stranger-e2e")
	h.agentStatus("stranger-e2e", paneID, "pi", "idle",
		"--parent-session", "somebody-else-e2e",
		"--inbox", in.Path)

	out := h.pipeKido("alpha", "steer.out", "stop what you are doing",
		"steer_subagent", "--", "stranger-e2e")
	if !strings.Contains(out, "rc=0") {
		t.Fatalf("kido steer_subagent from a shell = %q, want rc=0: a caller with no record is nobody's ancestor and is allowed to act on anything", out)
	}
	if strings.Contains(out, "descendant") {
		t.Errorf("kido steer_subagent output = %q, want no descendant refusal for a record-less caller", out)
	}
	h.waitEnvelope(in, `"kind":"steer"`, "stop what you are doing")
}
