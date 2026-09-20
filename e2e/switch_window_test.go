package e2e

import (
	"bytes"
	"fmt"
	"os/exec"
	"strings"
	"testing"
)

// clientWindow returns the client's current session (via list-clients) and,
// within it, the name of that session's active window (via list-windows):
// the window a client displays is the one its session currently has active,
// there being no separate per-client notion of "current window".
func (h *harness) clientWindow() (session, window string) {
	h.t.Helper()
	session = h.clientSession()
	if session == "" {
		return "", ""
	}
	out := h.in("list-windows", "-t", session, "-F", "#{window_active}\t#{window_name}")
	for _, line := range strings.Split(out, "\n") {
		active, name, ok := strings.Cut(line, "\t")
		if ok && active == "1" {
			return session, name
		}
	}
	return session, ""
}

// waitWindow waits until the client sits on session's window named window.
func (h *harness) waitWindow(session, window string) {
	h.t.Helper()
	h.waitFor(func() bool {
		s, w := h.clientWindow()
		return s == session && w == window
	}, settle, func() string {
		s, w := h.clientWindow()
		return fmt.Sprintf("client on %s:%s (is %s:%s)", session, window, s, w)
	})
}

// renameWindow renames session's window at index to name.
func (h *harness) renameWindow(session string, index int, name string) {
	h.t.Helper()
	h.in("rename-window", "-t", fmt.Sprintf("%s:%d", session, index), name)
}

// addWindow opens a second, named window in session (a bare shell pane) and
// waits for it to exist.
func (h *harness) addWindow(session, name string) {
	h.t.Helper()
	h.newWindow(session, name)
	h.waitFor(func() bool {
		out := h.in("list-windows", "-t", session, "-F", "#{window_name}")
		return hasLine(strings.Split(out, "\n"), name)
	}, settle, msgf("session %s has window %s", session, name))
}

// runSwitchWindow runs `kido switch-window <dir> -client <h.client>` against
// the inner server, the way a key binding's run-shell would (see
// tmux/kido-side.tmux).
func (h *harness) runSwitchWindow(dir string) {
	h.t.Helper()
	tmuxEnv := h.in("display-message", "-p", "#{socket_path},#{pid},0")
	cmd := exec.Command(kidoBin, "switch-window", dir, "-client", h.client)
	cmd.Env = cleanEnv("TMUX=" + tmuxEnv)
	var errb bytes.Buffer
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		h.t.Fatalf("kido switch-window %s: %v\n%s", dir, err, errb.String())
	}
}

// setupSwitchWindowSessions builds three sessions "a", "c", "b" (a full
// second apart, so kido's order by session_created is a, c, b - not a
// rotation of tmux's own name order a, b, c), each with two windows named
// "<session>0" and "<session>1". It returns the harness with the client
// sitting on a's first window.
func setupSwitchWindowSessions(t *testing.T) *harness {
	t.Helper()
	h := start(t, "a")
	h.renameWindow("a", 0, "a0")
	h.addWindow("a", "a1")

	h.newSessionSpaced("c")
	h.renameWindow("c", 0, "c0")
	h.addWindow("c", "c1")

	h.newSessionSpaced("b")
	h.renameWindow("b", 0, "b0")
	h.addWindow("b", "b1")

	ca, cc, cb := h.sessionCreated("a"), h.sessionCreated("c"), h.sessionCreated("b")
	if !(ca < cc && cc < cb) {
		t.Fatalf("session_created not strictly increasing: a=%d c=%d b=%d", ca, cc, cb)
	}

	h.waitSession("a")
	h.waitWindow("a", "a0")
	return h
}

// TestSwitchWindowOrder checks that `kido switch-window next|prev` walks a
// single flat list across the whole server: kido's session order (oldest
// first, a, c, b here) with each session's windows in tmux's own order. The
// step from "a1" to "c0" is the case that distinguishes this from tmux's own
// next-window, which wraps inside one session (a1 -> a0); kido instead
// crosses into the next session's first window. The walk also proves the
// whole-server wrap: from the very last window ("b1") next goes to the very
// first ("a0").
func TestSwitchWindowOrder(t *testing.T) {
	t.Parallel()
	h := setupSwitchWindowSessions(t)

	h.runSwitchWindow("next") // a0 -> a1 (inside session a)
	h.waitWindow("a", "a1")

	h.runSwitchWindow("next") // a1 -> c0 (crosses into session c; tmux's own next-window would wrap to a0)
	h.waitWindow("c", "c0")

	h.runSwitchWindow("next") // c0 -> c1
	h.waitWindow("c", "c1")

	h.runSwitchWindow("next") // c1 -> b0 (crosses into session b)
	h.waitWindow("b", "b0")

	h.runSwitchWindow("next") // b0 -> b1
	h.waitWindow("b", "b1")

	h.runSwitchWindow("next") // b1 -> wrap -> a0, the very first window
	h.waitWindow("a", "a0")
}

// TestSwitchWindowOrderPrev checks that prev is the exact inverse of next,
// walking the same flat list backwards and wrapping from the very first
// window to the very last.
func TestSwitchWindowOrderPrev(t *testing.T) {
	t.Parallel()
	h := setupSwitchWindowSessions(t)

	h.runSwitchWindow("prev") // a0 -> wrap -> b1, the very last window
	h.waitWindow("b", "b1")

	h.runSwitchWindow("prev") // b1 -> b0
	h.waitWindow("b", "b0")

	h.runSwitchWindow("prev") // b0 -> c1 (crosses into session c)
	h.waitWindow("c", "c1")

	h.runSwitchWindow("prev") // c1 -> c0
	h.waitWindow("c", "c0")

	h.runSwitchWindow("prev") // c0 -> a1 (crosses into session a)
	h.waitWindow("a", "a1")

	h.runSwitchWindow("prev") // a1 -> a0
	h.waitWindow("a", "a0")
}

// TestSwitchWindowBinding checks the actual key binding documented in
// tmux/kido-side.tmux and the README: bind-key -n ... run-shell "kido
// switch-window next -client '#{client_name}'". It proves #{client_name}
// expands to the real client name when run-shell fires from a key binding,
// not just when the test drives kido directly with -client.
func TestSwitchWindowBinding(t *testing.T) {
	t.Parallel()
	h := setupSwitchWindowSessions(t)

	h.in("bind-key", "-n", "S-Down", "run-shell",
		fmt.Sprintf("%s switch-window next -client '#{client_name}'", kidoBin))
	h.in("bind-key", "-n", "S-Up", "run-shell",
		fmt.Sprintf("%s switch-window prev -client '#{client_name}'", kidoBin))

	h.sendKeys("S-Down") // a0 -> a1
	h.waitWindow("a", "a1")

	h.sendKeys("S-Down") // a1 -> c0 (crosses into session c)
	h.waitWindow("c", "c0")

	h.sendKeys("S-Up") // c0 -> a1
	h.waitWindow("a", "a1")
}

// TestSwitchWindowSingleWindow checks that switch-window is a no-op with
// only one window on the server.
func TestSwitchWindowSingleWindow(t *testing.T) {
	t.Parallel()
	h := start(t, "solo")

	h.runSwitchWindow("next")
	h.waitSession("solo")
	h.runSwitchWindow("prev")
	h.waitSession("solo")
}
