package e2e

import (
	"bytes"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

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

// newSessionSpaced waits out the remaining wall-clock second first:
// #{session_created} has one-second resolution, so sessions created
// within the same second would tie and fall back to name order, hiding
// the distinction these tests exist to catch.
func (h *harness) newSessionSpaced(name string) {
	h.t.Helper()
	time.Sleep(time.Until(time.Now().Truncate(time.Second).Add(time.Second)) + 50*time.Millisecond)
	h.newSession(name)
}

// runSwitchSession runs against the inner server the way a key binding's
// run-shell would (share/tmux/kido-tmux.conf).
func (h *harness) runSwitchSession(dir string) {
	h.t.Helper()
	tmuxEnv := h.in("display-message", "-p", "#{socket_path},#{pid},0")
	cmd := exec.Command(kidoBin, "switch-session", dir, "--client", h.client)
	cmd.Env = cleanEnv("TMUX=" + tmuxEnv)
	var errb bytes.Buffer
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		h.t.Fatalf("kido switch-session %s: %v\n%s", dir, err, errb.String())
	}
}

// `kido switch-session next|prev` must walk kido's session order (oldest
// first), not tmux's own name order. Sessions created "a", "c", "b" one
// full second apart give kido's order a, c, b by creation time, not a
// rotation of name order a, b, c: only kido's order sends the first
// "next" from "a" to "c" rather than "b".
