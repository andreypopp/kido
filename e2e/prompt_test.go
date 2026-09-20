package e2e

import (
	"fmt"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"

	"kido/internal/testutil"
)

// waitInbox waits until the fake inbox has received exactly the prompts in
// want.
func (h *harness) waitInbox(in *testutil.Inbox, want ...string) {
	h.t.Helper()
	h.waitFor(func() bool {
		got := in.Received()
		if len(got) != len(want) {
			return false
		}
		for i := range got {
			if got[i] != want[i] {
				return false
			}
		}
		return true
	}, settle, func() string {
		return fmt.Sprintf("inbox to receive %q (has %q)", want, in.Received())
	})
}

// claudePaneHere splits target's window (e.g. "alpha:") with the fake
// claude binary and titles it the way Claude Code does, without switching
// the client to it. Unlike claudePane, which opens a whole new window,
// this keeps the pane in target's own window, for testing kido prompt's
// window scope.
func (h *harness) claudePaneHere(target, title string) string {
	h.t.Helper()
	id := h.in("split-window", "-d", "-P", "-F", "#{pane_id}", "-t", target, claudeBin, "--")
	h.waitPaneCommand(id, "claude")
	h.title(id, title)
	return id
}

// runPrompt types a shell command line into the client's active pane (the
// harness starts focused on the session's plain shell) that pipes text
// into `kido prompt`, reporting its exit code. KIDO_STATE_DIR needs no
// spelling out: the inner server sets it in its global environment (see
// inner.conf in start), so every pane of every inner session inherits it.
func (h *harness) runPrompt(text string, args ...string) {
	h.t.Helper()
	cmd := fmt.Sprintf("printf %s | %s prompt %s; echo rc=$?",
		shellQuote(text), kidoBin, strings.Join(args, " "))
	h.sendLiteral(cmd)
	h.sendKeys("Enter")
}

// shellQuote wraps s in single quotes for a POSIX shell command line; the
// prompts used in these tests contain no single quotes.
func shellQuote(s string) string { return "'" + s + "'" }

// waitMain waits until sub appears anywhere on the captured screen,
// window area included (waitRow and friends only look at the sidebar
// column). Only useful for the currently active window's pane: a pane in
// another window is not on screen at all, however long this waits (see
// waitPaneText for that case).
func (h *harness) waitMain(sub string) {
	h.t.Helper()
	h.waitFor(func() bool {
		for _, l := range h.capture() {
			if strings.Contains(ansi.Strip(l), sub) {
				return true
			}
		}
		return false
	}, settle, msgf("screen shows %q", sub))
}

// paneText captures pane id's own screen on the inner server, regardless
// of whether that pane's window is the one currently on screen.
func (h *harness) paneText(id string) string {
	h.t.Helper()
	out, err := h.tmux(h.inner, "capture-pane", "-p", "-t", id)
	if err != nil {
		return ""
	}
	return out
}

// waitPaneText waits until pane id's own screen contains sub.
func (h *harness) waitPaneText(id, sub string) {
	h.t.Helper()
	h.waitFor(func() bool { return strings.Contains(h.paneText(id), sub) }, settle,
		func() string { return fmt.Sprintf("pane %s shows %q (is %q)", id, sub, h.paneText(id)) })
}

// TestPromptDefaultWindowOne checks the default scope: a Claude Code pane
// split into the caller's own window is found and sent to, without the
// session being searched at all — a second Claude Code pane sits in
// another window of the same session, so a naive "always search the
// session" implementation would see two candidates and exit 5 here.
func TestPromptDefaultWindowOne(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	inWindow := h.claudePaneHere("alpha:", "✳ Claude")
	h.claudePane("alpha", "✳ Other") // another window, same session

	h.runPrompt("hello there")
	h.waitMain("rc=0")
	h.waitPaneText(inWindow, "got: hello there")
}

// TestPromptDefaultWindowSeveral checks that several Claude Code panes in
// the window is exit 5 with no widening to the session (the window is not
// empty, so the search never widens).
func TestPromptDefaultWindowSeveral(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.claudePaneHere("alpha:", "✳ One")
	h.claudePaneHere("alpha:", "✳ Two")

	h.runPrompt("hi")
	h.waitMain("multiple agents found")
	h.waitMain("rc=5")
}

// TestPromptDefaultSessionOne checks that the default scope widens to the
// session when the window has no Claude Code pane at all, finding the one
// in another window.
func TestPromptDefaultSessionOne(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.claudePane("alpha", "✳ Claude") // a new window, not the shell's own

	h.runPrompt("session scope")
	h.waitMain("rc=0")
	h.waitPaneText(pane, "got: session scope")
}

// TestPromptDefaultSessionSeveral checks that, with the window empty,
// several Claude Code panes elsewhere in the session is exit 5.
func TestPromptDefaultSessionSeveral(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.claudePane("alpha", "✳ One")
	h.claudePane("alpha", "✳ Two")

	h.runPrompt("hi")
	h.waitMain("multiple agents found")
	h.waitMain("rc=5")
}

// TestPromptDefaultNone checks that no Claude Code pane anywhere, window
// or session, is exit code 4.
func TestPromptDefaultNone(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	h.runPrompt("hi")
	h.waitMain("agent not found")
	h.waitMain("rc=4")
}

// TestPromptWindowFlagNoneElsewhereInSession checks that --window never
// widens to the session: with none in the window but one elsewhere in the
// session, it still exits 4.
func TestPromptWindowFlagNoneElsewhereInSession(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.claudePane("alpha", "✳ Claude") // a new window, not the shell's own

	h.runPrompt("hi", "--window")
	h.waitMain("agent not found")
	h.waitMain("rc=4")
}

// TestPromptInboxNative checks the native delivery path: a pane whose
// agent reported an inbox socket (`kido agent-status --inbox`) gets the
// prompt as a message over that socket, byte for byte, and no keystrokes
// at all - the pane's own screen must stay as the agent drew it, with none
// of the "got: ..." the fake agent echoes for send-keys input.
func TestPromptInboxNative(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.piPane("alpha", "π - alpha")
	in := testutil.StartInbox(t, "ok\n")
	h.agentStatus("pi-1", pane, "pi", "idle", "--inbox", in.Path)

	h.runPrompt("over the socket")
	h.waitMain("rc=0")
	h.waitInbox(in, "over the socket")
	// SendPrompt types the text and presses Enter before kido exits, so a
	// wrong send would already be on the pane's screen by now.
	if got := h.paneText(pane); strings.Contains(got, "got:") {
		t.Errorf("pane %s was typed into as well: %q", pane, got)
	}
}

// TestPromptInboxStaleFallsBack checks that a recorded socket nobody is
// listening on (an agent that died without clearing it) is not an error:
// nothing was delivered, so kido falls back to send-keys and still exits 0.
func TestPromptInboxStaleFallsBack(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.piPane("alpha", "π - alpha")
	h.agentStatus("pi-1", pane, "pi", "idle", "--inbox", testutil.StaleSocket(t))

	h.runPrompt("fall back to keys")
	h.waitMain("rc=0")
	h.waitPaneText(pane, "got: fall back to keys")
}

// TestPromptWindowFlagOne checks that --window sends to the window's own
// Claude Code pane.
func TestPromptWindowFlagOne(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.claudePaneHere("alpha:", "✳ Claude")

	h.runPrompt("hello there", "--window")
	h.waitMain("rc=0")
	h.waitPaneText(pane, "got: hello there")
}
