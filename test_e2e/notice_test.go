package e2e

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The delivery leg of the turn-completion notice: the settle-to-notice
// latency is share/pi/kido-status.ts's own to prove against a real extension,
// since this harness cannot host one. What e2e proves is the other half
// - a notice a child actually sends reaching its parent's inbox promptly
// - with a fake command calling `kido tool notify_parent` naming no target,
// so the parent it reaches can only have come from
// KIDO_AGENT_PARENT_SESSION set two processes earlier.
func TestSpawnedChildNoticeReachesParentInboxQuickly(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	// A real inbox so the notice goes over the socket, not a paste fallback.
	in := startInbox(t, "ok\n")
	parentPane := h.in("display-message", "-p", "-t", "alpha:", "#{pane_id}")
	h.agentStatus("parent-notice-e2e", parentPane, "pi", "idle",
		"--inbox", in.Path)

	taskFile := filepath.Join(h.dir, "task.txt")
	if err := os.WriteFile(taskFile, []byte("say hi"), 0o644); err != nil {
		t.Fatal(err)
	}
	outFile := filepath.Join(h.dir, "spawn.out")

	// Reports itself as a subagent (as kido-status.ts's session_start
	// would), then reports home exactly as pi's notify_parent tool does.
	child := fmt.Sprintf(
		"%s agent-status --agent pi --session child-notice-e2e "+
			"--parent-session parent-notice-e2e; "+
			"printf \"the answer is 42\" | %s tool notify_parent; "+
			"exec sleep 300",
		kidoBin, kidoBin)
	cmd := fmt.Sprintf("%s tool spawn_subagent --parent-pid 1 --parent-session parent-notice-e2e --name kid-notice-e2e --task-file %s -- /bin/sh -c %s > %s 2>&1",
		kidoBin, taskFile, shellQuote(child), outFile)

	t0 := time.Now()
	h.sendLiteral(cmd)
	h.sendKeys("Enter")

	h.waitFor(func() bool { return len(in.Received()) > 0 }, settle,
		msgf("the parent's inbox to receive the child's notice"))
	elapsed := time.Since(t0)
	t.Logf("measured child-notice -> parent-inbox latency: %s", elapsed)
	// Loose relative to settle: bounds a regression tying delivery to
	// something interval-shaped, not the ordinary cost of spawning.
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
