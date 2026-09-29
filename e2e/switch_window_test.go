package e2e

import (
	"bytes"
	"fmt"
	"os/exec"
	"strings"
	"testing"
)

// clientWindow asks the client itself, not the session's active window
// by name: tmux splits a target on "." and ":", so a session named
// "team.build" is not found by name - the bug some of these tests cover.
func (h *harness) clientWindow() (session, window string) {
	h.t.Helper()
	out := h.in("display-message", "-p", "-t", h.client, "#{client_session}\t#{window_name}")
	session, window, ok := strings.Cut(strings.TrimSpace(out), "\t")
	if !ok {
		return "", ""
	}
	return session, window
}

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

func (h *harness) renameWindow(session string, index int, name string) {
	h.t.Helper()
	h.in("rename-window", "-t", fmt.Sprintf("%s:%d", session, index), name)
}

func (h *harness) addWindow(session, name string) {
	h.t.Helper()
	h.newWindow(session, name)
	h.waitFor(func() bool {
		out := h.in("list-windows", "-t", session, "-F", "#{window_name}")
		return hasLine(strings.Split(out, "\n"), name)
	}, settle, msgf("session %s has window %s", session, name))
}

// markSubagent sets @kido_run on session's window's active pane - the
// pane-scoped mark Tmux.Exec.switch_window and Reap.sweep
// trust to know a window is a subagent's, with no status record needed.
func (h *harness) markSubagent(session, window string) {
	h.t.Helper()
	h.in("set-option", "-p", "-t", session+":"+window, "@kido_run", "run-"+session+"-"+window)
}

// selectWindow puts the client directly on session's window, bypassing
// kido - the way a user's own Enter into a subagent's window would land.
func (h *harness) selectWindow(session, window string) {
	h.t.Helper()
	h.in("switch-client", "-c", h.client, "-t", session, ";",
		"select-window", "-t", session+":"+window)
	h.waitWindow(session, window)
}

func (h *harness) runSwitchWindow(dir string) {
	h.t.Helper()
	tmuxEnv := h.in("display-message", "-p", "#{socket_path},#{pid},0")
	cmd := exec.Command(kidoBin, "switch-window", dir, "--client", h.client)
	cmd.Env = cleanEnv("TMUX=" + tmuxEnv)
	var errb bytes.Buffer
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		h.t.Fatalf("kido switch-window %s: %v\n%s", dir, err, errb.String())
	}
}

// setupSwitchWindowSessions builds sessions "a", "c", "b" a full second
// apart, so kido's order by session_created is a, c, b - not a rotation
// of tmux's own name order a, b, c - each with windows "<session>0/1".
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

// `kido switch-window next|prev` walks a single flat list across the
// whole server: kido's session order with each session's windows in
// tmux's own order. "a1" -> "c0" distinguishes this from tmux's own
// next-window, which wraps inside one session (a1 -> a0).
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

// prev is the exact inverse of next, walking the same flat list
// backwards and wrapping from the very first window to the very last.
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

// The actual key binding in tmux/kido-tmux.conf and the README:
// bind-key -n ... run-shell "kido switch-window next --client
// '#{client_name}'", proving #{client_name} expands when run-shell fires
// from a key binding, not just when the test drives kido with --client.
func TestSwitchWindowBinding(t *testing.T) {
	t.Parallel()
	h := setupSwitchWindowSessions(t)

	h.in("bind-key", "-n", "S-Down", "run-shell",
		fmt.Sprintf("%s switch-window next --client '#{client_name}'", kidoBin))
	h.in("bind-key", "-n", "S-Up", "run-shell",
		fmt.Sprintf("%s switch-window prev --client '#{client_name}'", kidoBin))

	h.sendKeys("S-Down") // a0 -> a1
	h.waitWindow("a", "a1")

	h.sendKeys("S-Down") // a1 -> c0 (crosses into session c)
	h.waitWindow("c", "c0")

	h.sendKeys("S-Up") // c0 -> a1
	h.waitWindow("a", "a1")
}

func TestSwitchWindowSingleWindow(t *testing.T) {
	t.Parallel()
	h := start(t, "solo")

	h.runSwitchWindow("next")
	h.waitSession("solo")
	h.runSwitchWindow("prev")
	h.waitSession("solo")
}

// a1 and c1, each marked @kido_run, must be stepped over entirely: the
// walk becomes a0, c0, b0, b1, not the six-window list
// TestSwitchWindowOrder walks.
func TestSwitchWindowSkipsSubagentWindows(t *testing.T) {
	t.Parallel()
	h := setupSwitchWindowSessions(t)
	h.markSubagent("a", "a1")
	h.markSubagent("c", "c1")

	h.runSwitchWindow("next") // a0 -> c0, skipping a1
	h.waitWindow("c", "c0")
	h.runSwitchWindow("next") // c0 -> b0, skipping c1
	h.waitWindow("b", "b0")
	h.runSwitchWindow("next") // b0 -> b1
	h.waitWindow("b", "b1")
	h.runSwitchWindow("next") // b1 -> wrap -> a0
	h.waitWindow("a", "a0")

	h.runSwitchWindow("prev") // a0 -> wrap -> b1
	h.waitWindow("b", "b1")
	h.runSwitchWindow("prev") // b1 -> b0
	h.waitWindow("b", "b0")
	h.runSwitchWindow("prev") // b0 -> c0, skipping c1
	h.waitWindow("c", "c0")
	h.runSwitchWindow("prev") // c0 -> a0, skipping a1
	h.waitWindow("a", "a0")
}

// Starting from a subagent window reached some other way (not by
// cycling with S-Up/S-Down) must still skip over further subagent
// windows: a1, c0 and c1 are marked, so from a1 next must cross two
// consecutive subagent windows to reach b0 - landing on c0 unskipped is
// exactly the bug an unfixed walk starting outside its own reachable set
// would show.
func TestSwitchWindowFromInsideSubagent(t *testing.T) {
	t.Parallel()
	h := setupSwitchWindowSessions(t)
	h.markSubagent("a", "a1")
	h.markSubagent("c", "c0")
	h.markSubagent("c", "c1")

	h.selectWindow("a", "a1") // land inside a subagent window directly
	h.runSwitchWindow("next") // a1 -> b0, skipping c0 and c1
	h.waitWindow("b", "b0")

	h.selectWindow("c", "c1") // another subagent window, deeper in the run
	h.runSwitchWindow("prev") // c1 -> a0, skipping c0 and a1
	h.waitWindow("a", "a0")
}

// The degenerate case where only one window on the whole server is not
// a subagent's: switch-window is a no-op when that window is already
// current, but still reaches it from inside any subagent window - not a
// blanket no-op on count<2, which would strand a user inside a subagent
// window with one top-level window elsewhere.
func TestSwitchWindowSoleTopLevelWindow(t *testing.T) {
	t.Parallel()
	h := setupSwitchWindowSessions(t)
	for _, w := range []struct{ session, window string }{
		{"a", "a1"}, {"c", "c0"}, {"c", "c1"}, {"b", "b0"}, {"b", "b1"},
	} {
		h.markSubagent(w.session, w.window)
	}

	// a0 is the sole top-level window and already current: no-op.
	h.runSwitchWindow("next")
	h.waitWindow("a", "a0")
	h.runSwitchWindow("prev")
	h.waitWindow("a", "a0")

	// From inside a subagent window, either direction reaches the lone
	// top-level window rather than stalling.
	h.selectWindow("c", "c0")
	h.runSwitchWindow("next")
	h.waitWindow("a", "a0")

	h.selectWindow("b", "b1")
	h.runSwitchWindow("prev")
	h.waitWindow("a", "a0")
}

// The other degenerate case: every window carries the mark, so there is
// no top-level window to land on. switch-window must not spin (the walk
// is bounded to one pass) and must not move the client anywhere.
func TestSwitchWindowAllSubagentWindows(t *testing.T) {
	t.Parallel()
	h := setupSwitchWindowSessions(t)
	for _, w := range []struct{ session, window string }{
		{"a", "a0"}, {"a", "a1"}, {"c", "c0"}, {"c", "c1"}, {"b", "b0"}, {"b", "b1"},
	} {
		h.markSubagent(w.session, w.window)
	}

	h.runSwitchWindow("next")
	h.waitWindow("a", "a0")
	h.runSwitchWindow("prev")
	h.waitWindow("a", "a0")
}

// A session name containing a dot is the case tmux's target parser gets
// wrong: `switch-client -t team.build` splits the name and looks for
// pane "build" of window "team", failing with "can't find pane". Both
// switch commands therefore target a session by its id.
func TestSwitchWindowIntoADottedSessionName(t *testing.T) {
	h := start(t, "plain")
	h.renameWindow("plain", 0, "p0")
	h.newSessionSpaced("team.build")
	h.renameWindow("team.build", 0, "t0")

	h.selectWindow("plain", "p0")
	h.runSwitchWindow("next")
	h.waitWindow("team.build", "t0")

	h.runSwitchWindow("prev")
	h.waitWindow("plain", "p0")
}

// switch-session targets a session by name too, and breaks the same way.
func TestSwitchSessionIntoADottedSessionName(t *testing.T) {
	h := start(t, "plain")
	h.newSessionSpaced("team.build")

	h.waitSession("plain")
	h.runSwitchSession("next")
	h.waitSession("team.build")

	h.runSwitchSession("prev")
	h.waitSession("plain")
}
