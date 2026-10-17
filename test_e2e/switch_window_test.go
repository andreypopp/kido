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
	var out, errb bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		h.t.Fatalf("kido switch-window %s: %v\n%s", dir, err, errb.String())
	}
	if out.Len() != 0 {
		h.t.Fatalf("kido switch-window %s stdout = %q, want empty", dir, out.String())
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

// Session/window order, the real key bindings, the focused and unfocused
// sidebar keys, and the session switch, all on one a/c/b layout built once.
func TestSwitchOrderAndKeys(t *testing.T) {
	t.Parallel()
	h := setupSwitchWindowSessions(t) // a, c, b by creation, each with two windows

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

	// One skip step: a marked subagent window must be stepped over.
	h.markSubagent("a", "a1")
	h.markSubagent("c", "c1")
	h.selectWindow("a", "a0")
	h.runSwitchWindow("next") // a0 -> c0, skipping a1
	h.waitWindow("c", "c0")
	h.runSwitchWindow("next") // c0 -> b0, skipping c1
	h.waitWindow("b", "b0")
	h.in("set-option", "-p", "-t", "a:a1", "@kido_run", "")
	h.in("set-option", "-p", "-t", "c:c1", "@kido_run", "")
	h.selectWindow("a", "a0")

	focusSidebar(h)
	h.waitSelectedLine(2)
	h.sendKeys("S-Down") // a0 -> a1, inside session a
	h.waitWindow("a", "a1")
	h.waitSelectedLine(3)
	if !h.clientFocused() {
		t.Fatal("shift+down released the sidebar's keyboard focus")
	}
	h.sendKeys("S-Down") // a1 -> c0, crossing into session c
	h.waitWindow("c", "c0")
	h.waitSelectedLine(5)
	if !h.clientFocused() {
		t.Fatal("shift+down released the sidebar's keyboard focus")
	}
	h.sendKeys("S-Up") // c0 -> a1, back across the session boundary
	h.waitWindow("a", "a1")
	h.waitSelectedLine(3)
	if !h.clientFocused() {
		t.Fatal("shift+up released the sidebar's keyboard focus")
	}

	h.sendKeys("Escape")
	h.waitFocused(false)
	h.selectWindow("a", "a0")
	h.waitWindow("a", "a0")
	h.sendKeys("S-Down") // a0 -> a1
	h.waitWindow("a", "a1")
	if h.clientFocused() {
		t.Fatal("shift+down gave the sidebar keyboard focus")
	}
	h.sendKeys("S-Down") // a1 -> c0
	h.waitWindow("c", "c0")
	if h.clientFocused() {
		t.Fatal("shift+down gave the sidebar keyboard focus")
	}
	h.sendKeys("S-Up") // c0 -> a1
	h.waitWindow("a", "a1")
	if h.clientFocused() {
		t.Fatal("shift+up gave the sidebar keyboard focus")
	}

	h.runSwitchSession("next") // a -> c (kido order; tmux name order would say b)
	h.waitSession("c")
	h.runSwitchSession("next") // c -> b
	h.waitSession("b")
	h.runSwitchSession("next") // b -> wrap -> a
	h.waitSession("a")
	h.runSwitchSession("prev") // a -> wrap -> b
	h.waitSession("b")

	h.in("bind-key", "-n", "S-Down", "run-shell",
		fmt.Sprintf("%s switch-session next --client '#{client_name}'", kidoBin))
	h.in("bind-key", "-n", "S-Up", "run-shell",
		fmt.Sprintf("%s switch-session prev --client '#{client_name}'", kidoBin))
	h.in("switch-client", "-c", h.client, "-t", "a")
	h.waitSession("a")
	h.sendKeys("S-Down") // a -> c
	h.waitSession("c")
	h.sendKeys("S-Up") // c -> a
	h.waitSession("a")
}

func TestSwitchWindowBindingIsSilent(t *testing.T) {
	t.Parallel()
	h := start(t, "a")
	h.renameWindow("a", 0, "a0")
	h.addWindow("a", "a1")
	windowID := h.in("display-message", "-p", "-t", "a:a1", "#{window_id}")

	h.sendKeys("S-Down")
	h.waitWindow("a", "a1")
	for _, target := range []string{"a:a0", "a:a1"} {
		mode := h.in("display-message", "-p", "-t", target, "#{pane_in_mode}")
		capture := h.in("capture-pane", "-p", "-t", target)
		if mode != "0" || strings.Contains(capture, windowID) {
			t.Fatalf("S-Down left run-shell output in %s: pane_in_mode=%s, capture=%q", target, mode, capture)
		}
	}
}

func TestSwitchSingleWindowAndSession(t *testing.T) {
	t.Parallel()
	h := start(t, "solo")

	h.runSwitchWindow("next")
	h.waitSession("solo")
	h.runSwitchWindow("prev")
	h.waitSession("solo")
	h.runSwitchSession("next")
	h.waitSession("solo")
	h.runSwitchSession("prev")
	h.waitSession("solo")
}

// A session name containing "." is not a tmux target syntax if it is passed
// where a target is expected: both switch-window and switch-session must treat
// the whole name as one session.
func TestSwitchIntoADottedSessionName(t *testing.T) {
	t.Parallel()
	h := start(t, "plain")
	h.renameWindow("plain", 0, "p0")
	h.newSessionSpaced("team.build")
	h.renameWindow("team.build", 0, "t0")

	h.selectWindow("plain", "p0")
	h.runSwitchWindow("next")
	h.waitWindow("team.build", "t0")
	h.runSwitchWindow("prev")
	h.waitWindow("plain", "p0")

	h.waitSession("plain")
	h.runSwitchSession("next")
	h.waitSession("team.build")
	h.runSwitchSession("prev")
	h.waitSession("plain")
}

func TestSwitchWindowFromHoistedSubagent(t *testing.T) {
	t.Parallel()
	h := start(t, "a")
	h.renameWindow("a", 0, "a0")
	h.liveParent("a", "parent-a0")
	h.addWindow("a", "a1")
	h.subagentWindow("a", "s", "child-s", "parent-a0")
	h.addWindow("a", "a2")
	h.in("bind-key", "-n", "S-Down", "run-shell",
		fmt.Sprintf("%s switch-window next --client '#{client_name}'", kidoBin))
	h.in("bind-key", "-n", "S-Up", "run-shell",
		fmt.Sprintf("%s switch-window prev --client '#{client_name}'", kidoBin))

	h.selectWindow("a", "s")
	h.sendKeys("S-Down")
	h.waitWindow("a", "a1")

	h.selectWindow("a", "s")
	h.sendKeys("S-Up")
	h.waitWindow("a", "a0")
}

func TestSwitchWindowNestedSiblings(t *testing.T) {
	t.Parallel()
	h := start(t, "a")
	h.renameWindow("a", 0, "root")
	h.liveParent("a", "root-session")
	h.addWindow("a", "top")
	h.subagentWindow("a", "child", "child-session", "root-session")
	h.subagentWindow("a", "grandchild", "grandchild-session", "child-session")
	h.subagentWindow("a", "sibling", "sibling-session", "root-session")

	for _, mode := range []string{"cli", "unfocused", "focused"} {
		t.Run(mode, func(t *testing.T) {
			if mode == "focused" {
				focusSidebar(h)
			}
			for _, step := range []struct{ from, direction, to string }{
				{"child", "next", "sibling"},
				{"sibling", "prev", "child"},
				{"child", "prev", "root"},
				{"grandchild", "prev", "child"},
				{"grandchild", "next", "top"},
				{"sibling", "next", "top"},
				{"root", "next", "top"},
				{"top", "next", "root"},
			} {
				h.selectWindow("a", step.from)
				if mode == "cli" {
					h.runSwitchWindow(step.direction)
				} else if step.direction == "next" {
					h.sendKeys("S-Down")
				} else {
					h.sendKeys("S-Up")
				}
				h.waitWindow("a", step.to)
			}
		})
	}
}

func TestSwitchDiscoversClientOnServerSocket(t *testing.T) {
	t.Parallel()
	h := start(t, "a")
	h.renameWindow("a", 0, "a0")
	h.addWindow("a", "a1")
	h.newSession("b")
	h.waitWindow("a", "a0")
	// Client discovery here is scoped to the server, not control-client filtering.
	h.in("set-option", "-g", "side-status-command", "")
	h.waitControlClients(0)

	for _, command := range []string{"switch-window", "switch-session"} {
		cmd := exec.Command(kidoBin, command, "next", "--server", h.stateDir)
		cmd.Env = cleanEnv("KIDO_STATE_DIR="+serverDir(t), "TMUX_SIDE_CLIENT=")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("kido %s --server without --client: %v\n%s", command, err, out)
		}
		if command == "switch-window" {
			h.waitWindow("a", "a1")
		} else {
			h.waitSession("b")
		}
	}
}

// An explicit server wins over a private default with no running server.
func TestSwitchWindowSocket(t *testing.T) {
	t.Parallel()
	h := start(t, "a")
	h.renameWindow("a", 0, "a0")
	h.addWindow("a", "a1")
	h.waitWindow("a", "a0")

	run := func(args ...string) error {
		cmd := exec.Command(kidoBin, append([]string{"switch-window", "next", "--client", h.client}, args...)...)
		cmd.Env = cleanEnv("TMUX=", "TMUX_PANE=", "KIDO_STATE_DIR="+serverDir(t))
		return cmd.Run()
	}
	if err := run(); err == nil {
		t.Errorf("switch-window without --server succeeded against an empty default")
	}
	if _, w := h.clientWindow(); w != "a0" {
		t.Fatalf("switch-window without --server moved the client to %s", w)
	}
	if err := run("--server", h.stateDir); err != nil {
		t.Fatalf("switch-window --server: %v", err)
	}
	h.waitWindow("a", "a1")
}
