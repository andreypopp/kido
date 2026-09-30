package e2e

import (
	"fmt"
	"strings"
	"testing"
	"time"
)

// rowFor returns the sidebar row of the pane whose title contains name.
func (h *harness) rowFor(name string) string {
	for _, l := range h.rows() {
		if strings.Contains(l, name) {
			return strings.TrimSpace(l)
		}
	}
	return ""
}

// waitGlyph waits until the agent pane titled title shows glyph in its
// indicator field. The field is two columns wide whatever it holds, so
// every label starts at the same place; an empty glyph is idle.
func (h *harness) waitGlyph(title, glyph string) {
	h.t.Helper()
	want := "╶" + indField(glyph) + title
	h.waitFor(func() bool { return h.rowFor(title) == want }, settle,
		func() string { return fmt.Sprintf("row %q (is %q)", want, h.rowFor(title)) })
}

// TestClaudeStatuses walks a Claude pane through every hook event and
// checks the glyph kido shows for it.
func TestClaudeStatuses(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.claudePane("alpha", "✳ Tmux config")

	for _, c := range []struct {
		glyph string
		event []string
	}{
		{"", []string{"SessionStart"}},
		{"◼", []string{"PreToolUse", "tool_name", "Bash"}},
		{"◆", []string{"PreToolUse", "tool_name", "AskUserQuestion"}},
		{"◼", []string{"PostToolUse"}},
		{"◆", []string{"PermissionRequest"}},
		{"◼", []string{"UserPromptSubmit"}},
		{"◆", []string{"Notification", "notification_type", "permission_prompt"}},
		{"◌", []string{"PreCompact", "trigger", "auto"}},
		{"◼", []string{"PostCompact", "trigger", "auto"}},
	} {
		h.hook("sess-1", pane, c.event[0], c.event[1:]...)
		h.waitGlyph("Tmux config", c.glyph)
	}

	if got := h.rowFor("Tmux config"); got != "╶◼ Tmux config" { // marker stripped from the pane title
		t.Errorf("row = %q", got)
	}

	h.hook("sess-1", pane, "SessionEnd") // drops the state; pane still runs claude, falls back to "?"
	h.waitGlyph("Tmux config", "?")
}

// TestClaudeUnknown checks the "?" glyph: a pane running claude that has
// never reported through the hook.
func TestClaudeUnknown(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.claudePane("alpha", "✳ No hook")
	h.waitGlyph("No hook", "?")
}

// TestClaudeDone checks that a turn ending while the user is elsewhere
// shows "✓ done" until the pane is visited.
func TestClaudeDone(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.newSession("beta")
	pane := h.claudePane("beta", "✳ Away job")

	h.hook("sess-away", pane, "PreToolUse", "tool_name", "Bash")
	h.waitGlyph("Away job", "◼")

	h.hook("sess-away", pane, "Stop") // client on alpha, beta unwatched
	h.waitGlyph("Away job", "✓")

	// Visiting it marks it seen.
	h.in("switch-client", "-c", h.client, "-t", pane)
	h.in("select-window", "-t", pane)
	h.in("select-pane", "-t", pane)
	h.waitSession("beta")
	h.waitGlyph("Away job", "")
}

// TestClaudeBackgroundWork checks the pane of a turn that ended with
// background work still running: it stays running until the work is done,
// and only the SubagentStop reporting nothing left turns it into "✓ done".
func TestClaudeBackgroundWork(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.newSession("beta")
	pane := h.claudePane("beta", "✳ Background job")

	running := []any{map[string]any{"status": "running"}}
	h.hook("sess-bg", pane, "PreToolUse", "tool_name", "Bash")
	h.waitGlyph("Background job", "◼")

	h.hookPayload("sess-bg", pane, "Stop", map[string]any{"background_tasks": running})
	h.waitGlyph("Background job", "◼")

	h.hookPayload("sess-bg", pane, "PreToolUse", map[string]any{"agent_id": "a", "tool_name": "Bash"})
	h.hookPayload("sess-bg", pane, "SubagentStop", map[string]any{"agent_id": "a", "background_tasks": running})
	// idle_prompt fires a minute after every Stop and knows nothing of the background job.
	h.hook("sess-bg", pane, "Notification", "notification_type", "idle_prompt")
	time.Sleep(time.Second)
	if got := h.rowFor("Background job"); got != "╶◼ Background job" {
		t.Fatalf("row = %q, want still running while the background job is", got)
	}

	// The last background task finishing ends the turn.
	h.hookPayload("sess-bg", pane, "SubagentStop", map[string]any{"agent_id": "a", "background_tasks": []any{}})
	h.waitGlyph("Background job", "✓")
}

// TestClaudeSubagentMidTurn checks the other side of it: a subagent
// finishing while the main loop is still working says nothing about the
// turn, so the pane stays running.
func TestClaudeSubagentMidTurn(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.newSession("beta")
	pane := h.claudePane("beta", "✳ Midturn job")

	h.hook("sess-mid", pane, "PreToolUse", "tool_name", "Bash")
	h.waitGlyph("Midturn job", "◼")

	h.hookPayload("sess-mid", pane, "SubagentStop", map[string]any{"agent_id": "a", "background_tasks": []any{}})
	time.Sleep(time.Second)
	if got := h.rowFor("Midturn job"); got != "╶◼ Midturn job" {
		t.Fatalf("row = %q, want still running: the main loop never stopped", got)
	}
}

// TestClaudeDismissedPrompt checks the one status kido works out for
// itself: dismissing a question or denying a permission fires no hook at
// all, so the waiting glyph would stick until Claude Code's idle_prompt
// notification a minute later. kido reads the pane instead.
func TestClaudeDismissedPrompt(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.newSession("beta")
	pane := h.claudePane("beta", "✳ Dismissed") // fake starts on a question dialog

	h.hook("sess-dismiss", pane, "PreToolUse", "tool_name", "AskUserQuestion")
	h.waitGlyph("Dismissed", "◆")

	// No hook fires either; the footer is what keeps the pane from reading idle.
	h.fakeClaude(pane, "busy")
	time.Sleep(time.Second)
	if got := h.rowFor("Dismissed"); got != "╶◆ Dismissed" {
		t.Fatalf("row = %q, want the waiting glyph while work is in flight", got)
	}

	h.fakeClaude(pane, "esc") // nothing running, unwatched pane reads as done
	h.waitGlyph("Dismissed", "✓")

	h.hook("sess-dismiss", pane, "UserPromptSubmit") // a hook still has the last word
	h.waitGlyph("Dismissed", "◼")
}

// TestAttentionKeys checks n/N cycling through the sessions that want the
// user: waiting ones and done ones.
func TestAttentionKeys(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.newSession("beta")
	h.newSession("gamma")
	h.waitRows(6)

	betaPane := h.claudePane("beta", "✳ Waiting job")
	gammaPane := h.claudePane("gamma", "✳ Done job")
	h.hook("sess-b", betaPane, "PermissionRequest")
	h.hook("sess-g", gammaPane, "Stop")
	h.waitGlyph("Waiting job", "◆")
	h.waitGlyph("Done job", "✓")

	focusSidebar(h)
	h.waitSelected(shell) // alpha's own pane

	h.sendKeys("n")
	h.waitSelected("Waiting job")
	h.sendKeys("n")
	h.waitSelected("Done job")
	h.sendKeys("n") // wraps back around
	h.waitSelected("Waiting job")
	h.sendKeys("N")
	h.waitSelected("Done job")
}
