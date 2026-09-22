package e2e

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"kido/internal/testutil"
)

// TestSpawnedChildNoticeReachesParentInboxQuickly is the delivery leg of
// the turn-completion notice (pi/kido-status.ts's turnSettled,
// pi/kido-agents.ts's sendTurnNotice): the settle-to-notice latency itself
// is TS's to prove, against a real extension, since this harness cannot
// host one. What e2e can and must prove is the other half of the path -
// a notice a child actually sends reaching its parent's inbox promptly -
// with a fake spawned command that calls `kido message --kind notice`
// itself, standing in for pi's own extension the way every other e2e
// subagent test stands a fake command in for pi.
func TestSpawnedChildNoticeReachesParentInboxQuickly(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	// The parent: a real inbox, and a state record advertising it, so
	// `kido message` can resolve "parent-notice-e2e" and deliver over the
	// socket rather than falling back to a paste.
	in := testutil.StartInbox(t, "ok\n")
	parentPane := h.in("display-message", "-p", "-t", "alpha:", "#{pane_id}")
	h.agentStatus("parent-notice-e2e", parentPane, "pi", "idle",
		"--instance", "parent-notice-e2e-inst", "--inbox", in.Path, "--protocol", "1")

	taskFile := filepath.Join(h.dir, "task.txt")
	if err := os.WriteFile(taskFile, []byte("say hi"), 0o644); err != nil {
		t.Fatal(err)
	}
	outFile := filepath.Join(h.dir, "spawn.out")

	// The fake child: reports itself as a subagent of the parent above
	// (as kido-status.ts's session_start would), then sends its own
	// completion notice exactly as sendTurnNotice/sendCompletionNotice do
	// - a `kido message --kind notice` call - before settling into a long
	// sleep so the window stays open for the assertions below.
	child := fmt.Sprintf(
		"%s agent-status --agent pi --session child-notice-e2e --status idle "+
			"--instance child-notice-e2e-inst --parent-instance parent-notice-e2e-inst; "+
			"printf \"the answer is 42\" | %s message --kind notice -- parent-notice-e2e; "+
			"exec sleep 300",
		kidoBin, kidoBin)
	cmd := fmt.Sprintf("%s spawn --parent-pid 1 --parent-instance parent-notice-e2e-inst --name kid-notice-e2e --task-file %s -- /bin/sh -c %s > %s 2>&1",
		kidoBin, taskFile, shellQuote(child), outFile)

	t0 := time.Now()
	h.sendLiteral(cmd)
	h.sendKeys("Enter")

	// settle/100ms polling: this harness's own convention (harness_test.go).
	h.waitFor(func() bool { return len(in.Received()) > 0 }, settle,
		msgf("the parent's inbox to receive the child's notice"))
	elapsed := time.Since(t0)
	t.Logf("measured child-notice -> parent-inbox latency: %s", elapsed)
	// Loose relative to settle (5s, chosen for tmux's own latencies, not
	// this path's): what this bounds is a regression that ties delivery
	// to something interval-shaped, not the ordinary cost of typing a
	// command line into a pane and spawning two subprocesses in reply.
	if elapsed > 2*time.Second {
		t.Errorf("notice delivery took %s, want well under the 30s heartbeat interval", elapsed)
	}

	msgs := in.Received()
	if len(msgs) == 0 || !strings.Contains(msgs[0], "the answer is 42") {
		t.Errorf("parent inbox received %q, want an envelope carrying the child's own notice text", msgs)
	}
	if !strings.Contains(msgs[0], `"kind":"notice"`) {
		t.Errorf("parent inbox received %q, want a v1 envelope of kind \"notice\"", msgs)
	}
}
