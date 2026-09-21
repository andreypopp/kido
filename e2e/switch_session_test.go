package e2e

import (
	"bytes"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"testing"
	"time"
)

// sessionCreated returns #{session_created} for name, or -1 if it is not on
// the inner server.
func (h *harness) sessionCreated(name string) int64 {
	h.t.Helper()
	out := h.in("list-sessions", "-F", "#{session_name}\t#{session_created}")
	for _, line := range strings.Split(out, "\n") {
		n, created, ok := strings.Cut(line, "\t")
		if ok && n == name {
			v, _ := strconv.ParseInt(created, 10, 64)
			return v
		}
	}
	return -1
}

// newSessionSpaced creates an inner session the way newSession does, but
// first waits out any remaining part of the current wall-clock second:
// #{session_created} only has one-second resolution, so sessions created
// within the same second would tie and fall back to name order, hiding the
// very distinction these tests exist to catch.
func (h *harness) newSessionSpaced(name string) {
	h.t.Helper()
	time.Sleep(time.Until(time.Now().Truncate(time.Second).Add(time.Second)) + 50*time.Millisecond)
	h.newSession(name)
}

// runSwitchSession runs `kido switch-session <dir> -client <h.client>`
// against the inner server, the way a key binding's run-shell would (see
// tmux/kido-side.tmux): TMUX names the inner server's socket, pid and a
// session, and -client carries the side status column's own client name.
func (h *harness) runSwitchSession(dir string) {
	h.t.Helper()
	tmuxEnv := h.in("display-message", "-p", "#{socket_path},#{pid},0")
	cmd := exec.Command(kidoBin, "switch-session", dir, "-client", h.client)
	cmd.Env = cleanEnv("TMUX=" + tmuxEnv)
	var errb bytes.Buffer
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		h.t.Fatalf("kido switch-session %s: %v\n%s", dir, err, errb.String())
	}
}

// TestSwitchSessionOrder checks that `kido switch-session next|prev` walks
// kido's session order (oldest first, ties by name), not tmux's own
// next/prev order (which walks by name). Sessions are created "a", "c",
// "b" (one full second apart, so #{session_created} cannot tie), giving
// kido's order a, c, b by creation time, which is not a rotation of tmux's
// name order a, b, c: only kido's order sends the first "next" from "a" to
// "c" rather than "b", so that step is what proves the sidebar's order and
// switch-session's order cannot drift apart.
func TestSwitchSessionOrder(t *testing.T) {
	t.Parallel()
	h := start(t, "a")
	h.newSessionSpaced("c")
	h.newSessionSpaced("b")

	ca, cc, cb := h.sessionCreated("a"), h.sessionCreated("c"), h.sessionCreated("b")
	if !(ca < cc && cc < cb) {
		t.Fatalf("session_created not strictly increasing: a=%d c=%d b=%d", ca, cc, cb)
	}

	// The client starts on "a" (the session start() created).
	h.waitSession("a")

	h.runSwitchSession("next") // a -> c (kido order; tmux name order would say b)
	h.waitSession("c")

	h.runSwitchSession("next") // c -> b
	h.waitSession("b")

	h.runSwitchSession("next") // b -> wrap -> a
	h.waitSession("a")

	h.runSwitchSession("prev") // a -> wrap -> b
	h.waitSession("b")
}

// TestSwitchSessionBinding checks the actual key binding documented in
// tmux/kido-side.tmux and the README: bind-key -n ... run-shell "kido
// switch-session next -client '#{client_name}'". It proves #{client_name}
// expands to the real client name when run-shell fires from a key binding,
// not just when the test drives kido directly with -client.
func TestSwitchSessionBinding(t *testing.T) {
	t.Parallel()
	h := start(t, "a")
	h.newSessionSpaced("c")
	h.newSessionSpaced("b")
	h.waitSession("a")

	h.in("bind-key", "-n", "S-Down", "run-shell",
		fmt.Sprintf("%s switch-session next -client '#{client_name}'", kidoBin))
	h.in("bind-key", "-n", "S-Up", "run-shell",
		fmt.Sprintf("%s switch-session prev -client '#{client_name}'", kidoBin))

	h.sendKeys("S-Down") // a -> c (kido order; tmux name order would say b)
	h.waitSession("c")

	h.sendKeys("S-Up") // c -> a
	h.waitSession("a")
}

// TestSwitchSessionSingleSession checks that switch-session is a no-op with
// only one session on the server.
func TestSwitchSessionSingleSession(t *testing.T) {
	t.Parallel()
	h := start(t, "solo")

	h.runSwitchSession("next")
	h.waitSession("solo")
	h.runSwitchSession("prev")
	h.waitSession("solo")
}
