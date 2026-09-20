package e2e

import (
	"fmt"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

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
// into `kido prompt`, reporting its exit code.
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

// TestPromptWindow checks the default scope: a Claude Code pane split
// into the caller's own window is found, gets the prompt, and kido prompt
// exits 0.
func TestPromptWindow(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.claudePaneHere("alpha:", "✳ Claude")

	h.runPrompt("hello there")
	h.waitMain("rc=0")
	h.waitPaneText(pane, "got: hello there")
}

// TestPromptSession checks --session: a Claude Code pane in another
// window of the same session is invisible to the default (window) scope
// but found with --session.
func TestPromptSession(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.claudePane("alpha", "✳ Claude") // a new window, not the shell's own

	h.runPrompt("window scope")
	h.waitMain("rc=4") // claude code not found: wrong window, no --session

	h.runPrompt("session scope", "--session")
	h.waitMain("rc=0")
	h.waitPaneText(pane, "got: session scope")
}

// TestPromptMultipleInSession checks that two Claude Code panes in scope
// is an error (ambiguous), exit code 5.
func TestPromptMultipleInSession(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.claudePane("alpha", "✳ One")
	h.claudePane("alpha", "✳ Two")

	h.runPrompt("hi", "--session")
	h.waitMain("multiple claude code found")
	h.waitMain("rc=5")
}

// TestPromptNone checks that no Claude Code pane anywhere is exit code 4.
func TestPromptNone(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	h.runPrompt("hi")
	h.waitMain("claude code not found")
	h.waitMain("rc=4")
}

// TestPromptFallbackFlagWindowOne checks that --fallback-to-session sends to
// the window's own Claude Code pane, and never widens to the session, when
// the window already has exactly one: a second Claude Code pane sits in
// another window of the same session, so a naive "always search the
// session" implementation would see two candidates and exit 5 here.
func TestPromptFallbackFlagWindowOne(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	inWindow := h.claudePaneHere("alpha:", "✳ Claude")
	h.claudePane("alpha", "✳ Other") // another window, same session

	h.runPrompt("hello there", "--fallback-to-session")
	h.waitMain("rc=0")
	h.waitPaneText(inWindow, "got: hello there")
}

// TestPromptFallbackFlagWindowSeveral checks that several Claude Code
// panes in the window is still exit 5 with --fallback-to-session: the
// window is not empty, so the search is never widened to the session.
func TestPromptFallbackFlagWindowSeveral(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.claudePaneHere("alpha:", "✳ One")
	h.claudePaneHere("alpha:", "✳ Two")

	h.runPrompt("hi", "--fallback-to-session")
	h.waitMain("multiple claude code found")
	h.waitMain("rc=5")
}

// TestPromptFallbackFlagSessionOne checks that --fallback-to-session
// widens to the session when the window has no Claude Code pane at all,
// finding the one in another window.
func TestPromptFallbackFlagSessionOne(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.claudePane("alpha", "✳ Claude") // a new window, not the shell's own

	h.runPrompt("session scope", "--fallback-to-session")
	h.waitMain("rc=0")
	h.waitPaneText(pane, "got: session scope")
}

// TestPromptFallbackFlagSessionSeveral checks that, with the window empty,
// several Claude Code panes elsewhere in the session is exit 5.
func TestPromptFallbackFlagSessionSeveral(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.claudePane("alpha", "✳ One")
	h.claudePane("alpha", "✳ Two")

	h.runPrompt("hi", "--fallback-to-session")
	h.waitMain("multiple claude code found")
	h.waitMain("rc=5")
}

// TestPromptFallbackFlagNone checks that no Claude Code pane anywhere,
// window or session, is exit code 4 with --fallback-to-session too.
func TestPromptFallbackFlagNone(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	h.runPrompt("hi", "--fallback-to-session")
	h.waitMain("claude code not found")
	h.waitMain("rc=4")
}

// TestPromptFlagsMutuallyExclusive checks that --session and
// --fallback-to-session together are rejected up front, before kido ever
// talks to tmux.
func TestPromptFlagsMutuallyExclusive(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	h.runPrompt("hi", "--session", "--fallback-to-session")
	h.waitMain("mutually exclusive")
	h.waitMain("rc=1")
}
