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
// indicator field. An empty glyph is the idle pane's empty field: the
// field is two columns wide whatever it holds, so every label starts at
// the same place. The field sits directly against the tree glyph, with
// no separating space of its own - that space lives inside the field,
// as the byte after the indicator (or the first of its two filler
// spaces).
func (h *harness) waitGlyph(title, glyph string) {
	h.t.Helper()
	want := "·" + indField(glyph) + title
	h.waitFor(func() bool { return h.rowFor(title) == want }, settle,
		func() string { return fmt.Sprintf("row %q (is %q)", want, h.rowFor(title)) })
}

// TestClaudeStatuses walks a Claude pane through every hook event and
// checks the glyph kido shows for it.
func TestClaudeStatuses(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	// A pane running claude, titled the way Claude Code titles it.
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

	// The title comes from the pane title with the leading marker gone.
	if got := h.rowFor("Tmux config"); got != "·◼ Tmux config" {
		t.Errorf("row = %q", got)
	}

	// SessionEnd drops the state: the pane still runs claude, so it falls
	// back to the "no hook data" glyph.
	h.hook("sess-1", pane, "SessionEnd")
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

	// The client is on alpha, so beta's pane is not being looked at.
	h.hook("sess-away", pane, "Stop")
	h.waitGlyph("Away job", "✓")

	// Visiting it marks it seen: plain idle again.
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
	// The client is on alpha, so beta's pane is not being looked at and a
	// finished turn shows the done glyph.
	pane := h.claudePane("beta", "✳ Background job")

	running := []any{map[string]any{"status": "running"}}
	h.hook("sess-bg", pane, "PreToolUse", "tool_name", "Bash")
	h.waitGlyph("Background job", "◼")

	// The turn ends, but a background subagent is still going.
	h.hookPayload("sess-bg", pane, "Stop", map[string]any{"background_tasks": running})
	h.waitGlyph("Background job", "◼")

	// Its own tool calls and turns keep arriving under this session id and
	// leave the pane where it is.
	h.hookPayload("sess-bg", pane, "PreToolUse", map[string]any{"agent_id": "a", "tool_name": "Bash"})
	h.hookPayload("sess-bg", pane, "SubagentStop", map[string]any{"agent_id": "a", "background_tasks": running})
	// So does the idle_prompt notification a minute after the Stop, which
	// knows nothing of the background job.
	h.hook("sess-bg", pane, "Notification", "notification_type", "idle_prompt")
	time.Sleep(time.Second)
	if got := h.rowFor("Background job"); got != "·◼ Background job" {
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
	if got := h.rowFor("Midturn job"); got != "·◼ Midturn job" {
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
	// The fake starts on a question dialog, matching the hook below.
	pane := h.claudePane("beta", "✳ Dismissed")

	h.hook("sess-dismiss", pane, "PreToolUse", "tool_name", "AskUserQuestion")
	h.waitGlyph("Dismissed", "◆")

	// Answering the question puts the input box back while the tool runs,
	// and no hook says so either: the footer is what keeps the pane from
	// being read as idle.
	h.fakeClaude(pane, "busy")
	time.Sleep(time.Second)
	if got := h.rowFor("Dismissed"); got != "·◆ Dismissed" {
		t.Fatalf("row = %q, want the waiting glyph while work is in flight", got)
	}

	// Dismissing it leaves the box with nothing running. The client is on
	// alpha, so the pane is not being looked at: it reads as done.
	h.fakeClaude(pane, "esc")
	h.waitGlyph("Dismissed", "✓")

	// A hook still has the last word.
	h.hook("sess-dismiss", pane, "UserPromptSubmit")
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
