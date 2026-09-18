package e2e

import (
	"strings"
	"testing"
	"time"
)

// slowPoll is an interval long enough that nothing a test sees within a
// second can have come from a poll: only tmux's control-mode
// notifications, delivered over kido's persistent connection, are that
// fast.
const slowPoll = "-interval=5s"

// controlClients returns the names of the inner server's control-mode
// clients: kido's connection, and nothing else.
func (h *harness) controlClients() []string {
	h.t.Helper()
	var names []string
	out := h.in("list-clients", "-F", "#{client_name}\t#{client_control_mode}")
	for _, line := range strings.Split(out, "\n") {
		if name, mode, _ := strings.Cut(line, "\t"); mode == "1" {
			names = append(names, name)
		}
	}
	return names
}

// waitControlClients waits until the inner server has n control clients and
// returns their names.
func (h *harness) waitControlClients(n int) []string {
	h.t.Helper()
	h.waitFor(func() bool { return len(h.controlClients()) == n }, settle,
		func() string { return msgf("%d control clients (are %q)", n, h.controlClients())() })
	return h.controlClients()
}

// waitQuickly is waitFor with a deadline short enough that only a
// notification can meet it; it reports how long the wait took.
func (h *harness) waitQuickly(cond func() bool, within time.Duration, describe func() string) time.Duration {
	h.t.Helper()
	began := time.Now()
	deadline := began.Add(within)
	for {
		if cond() {
			return time.Since(began)
		}
		if time.Now().After(deadline) {
			h.t.Fatalf("timed out after %v waiting for %s\n%s", within, describe(), h.diagnose())
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// rowCount is the number of non-empty sidebar rows.
func (h *harness) rowCount() int { h.t.Helper(); return len(h.rows()) }

// A new window shows up at once, long before the next poll: kido keeps one
// control-mode client and tmux tells it about the change.
func TestNotificationRefreshesBeforeNextPoll(t *testing.T) {
	h := start(t, "alpha", slowPoll)
	h.waitControlClients(1)
	h.waitRow("alpha")
	before := h.rowCount()

	h.newWindow("alpha", "fresh")
	// 1.5s is still a fifth of the poll interval, with room for a loaded
	// CI runner's pty round trips.
	took := h.waitQuickly(func() bool { return h.rowCount() == before+1 },
		1500*time.Millisecond, func() string { return msgf("%d rows (are %q)", before+1, h.rows())() })
	t.Logf("new window shown after %v", took)
}

// When the connection drops, kido re-dials and is live again within a
// couple of seconds, leaving exactly one control client behind.
func TestReconnectsAfterConnectionDrops(t *testing.T) {
	h := start(t, "alpha", slowPoll)
	before := h.rowCount()

	// Drop the connection the way a killed session would: the control
	// client goes away under kido's feet.
	for _, name := range h.waitControlClients(1) {
		h.in("detach-client", "-t", name)
	}

	dropped := time.Now()
	h.newWindow("alpha", "fresh")
	h.waitQuickly(func() bool { return h.rowCount() == before+1 },
		2*time.Second, func() string { return msgf("%d rows (are %q)", before+1, h.rows())() })
	t.Logf("reconnected and refreshed %v after the drop", time.Since(dropped))
	h.waitControlClients(1) // re-dialled once, not piled up
}

// Killing the session the connection is attached to leaves the sidebar
// up to date within a couple of seconds. detach-on-destroy is turned off
// first so the pty client (and with it kido) survives the kill.
func TestSessionKillRefreshesQuickly(t *testing.T) {
	h := start(t, "alpha", slowPoll)
	h.waitControlClients(1)
	h.in("set-option", "-g", "detach-on-destroy", "off")
	h.newSession("beta")

	h.in("kill-session", "-t", "alpha")
	took := h.waitQuickly(func() bool { return !hasLine(h.rows(), "alpha") },
		2*time.Second, func() string { return msgf("alpha gone (rows are %q)", h.rows())() })
	t.Logf("killed session dropped after %v", took)
	h.waitControlClients(1)

	// Still live afterwards.
	before := h.rowCount()
	h.newWindow("beta", "late")
	took = h.waitQuickly(func() bool { return h.rowCount() == before+1 },
		2*time.Second, func() string { return msgf("%d rows (are %q)", before+1, h.rows())() })
	t.Logf("post-kill window shown after %v", took)
}
