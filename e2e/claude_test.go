package e2e

import (
	"strings"
	"testing"
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

func (h *harness) waitGlyph(title, glyph string) {
	h.t.Helper()
	want := "· " + glyph + " " + title
	h.waitFor(func() bool { return h.rowFor(title) == want }, settle,
		"row "+want+" (is "+h.rowFor(title)+")")
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
		{"○", []string{"SessionStart"}},
		{"●", []string{"PreToolUse", "tool_name", "Bash"}},
		{"◆", []string{"PreToolUse", "tool_name", "AskUserQuestion"}},
		{"●", []string{"PostToolUse"}},
		{"◆", []string{"PermissionRequest"}},
		{"●", []string{"UserPromptSubmit"}},
		{"◆", []string{"Notification", "notification_type", "permission_prompt"}},
		{"◌", []string{"PreCompact", "trigger", "auto"}},
		{"●", []string{"PostCompact", "trigger", "auto"}},
	} {
		h.hook("sess-1", pane, c.event[0], c.event[1:]...)
		h.waitGlyph("Tmux config", c.glyph)
	}

	// The title comes from the pane title with the leading marker gone.
	if got := h.rowFor("Tmux config"); got != "· ● Tmux config" {
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
	h.waitGlyph("Away job", "●")

	// The client is on alpha, so beta's pane is not being looked at.
	h.hook("sess-away", pane, "Stop")
	h.waitGlyph("Away job", "✓")

	// Visiting it marks it seen: plain idle again.
	h.in("switch-client", "-c", h.client, "-t", pane)
	h.in("select-window", "-t", pane)
	h.in("select-pane", "-t", pane)
	h.waitSession("beta")
	h.waitGlyph("Away job", "○")
}

// TestAttentionKeys checks n/N cycling through the sessions that want the
// user: waiting ones and done ones.
func TestAttentionKeys(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.newSession("beta")
	h.newSession("gamma")
	h.waitFor(func() bool { return len(h.rows()) == 6 }, settle, "6 rows")

	betaPane := h.claudePane("beta", "✳ Waiting job")
	gammaPane := h.claudePane("gamma", "✳ Done job")
	h.hook("sess-b", betaPane, "PermissionRequest")
	h.hook("sess-g", gammaPane, "Stop")
	h.waitGlyph("Waiting job", "◆")
	h.waitGlyph("Done job", "✓")

	focusSidebar(h)
	h.waitSelected("zsh") // alpha's own pane

	h.sendKeys("n")
	h.waitSelected("Waiting job")
	h.sendKeys("n")
	h.waitSelected("Done job")
	h.sendKeys("n") // wraps back around
	h.waitSelected("Waiting job")
	h.sendKeys("N")
	h.waitSelected("Done job")
}
