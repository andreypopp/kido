package e2e

import (
	"fmt"
	"testing"
	"time"
)

// countRows is how many sidebar rows read exactly want.
func (h *harness) countRows(want string) int {
	h.t.Helper()
	n := 0
	for _, l := range h.rows() {
		if l == want {
			n++
		}
	}
	return n
}

// TestPiPaneLooksLikeAClaudePane checks that an agent that is not Claude
// Code gets exactly the row a Claude Code pane gets: a status indicator and
// the title, with nothing on screen saying which agent it is.
func TestPiPaneLooksLikeAClaudePane(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	// pi titles its pane "π - <session> - <cwd>", and reports its status
	// with `kido agent-status` instead of a Claude Code hook.
	pane := h.piPane("alpha", "π - deploy - kido")

	for _, c := range []struct{ status, glyph string }{
		{"idle", "○"},
		{"running", "●"},
		{"waiting", "◆"},
		{"compacting", "◌"},
	} {
		h.agentStatus("pi-1", pane, "pi", c.status)
		h.waitGlyph("deploy - kido", c.glyph)
	}

	// Only pi's marker is stripped: the session and directory pi named
	// stay in the row, and the row is built exactly as a Claude pane's.
	claude := h.claudePane("alpha", "✳ deploy - kido")
	h.hook("sess-c", claude, "UserPromptSubmit")
	h.agentStatus("pi-1", pane, "pi", "running")
	h.waitGlyph("deploy - kido", "●")
	h.waitFor(func() bool { return h.countRows("· ● deploy - kido") == 2 }, settle,
		func() string {
			return fmt.Sprintf("two identical rows for the pi and claude panes (rows are %q)", h.rows())
		})

	// --remove drops pi's record at shutdown; the pane is then just a
	// process again, not an agent, and shows its foreground command. The
	// claude pane is the one that keeps the title row.
	h.agentStatus("pi-1", pane, "pi", "", "--remove")
	h.waitFor(func() bool {
		return h.countRows("· ● deploy - kido") == 1 && h.countRows("· node") == 1
	}, settle, func() string {
		return fmt.Sprintf("the pi pane back to a plain node row (rows are %q)", h.rows())
	})
}

// TestPiReportedTitleWinsOverPaneTitle checks that a recorded --title is
// what the row shows, not the session name and cwd basename kido would
// otherwise recover by stripping pi's "π - " marker off the pane title:
// splitting on "-" would be wrong (a session name can itself contain " -
// "), and the extension already sends the exact name. It also checks that
// a report with no --title (an agent reporting a status change without
// repeating an unchanged title, or coalescing it away) keeps the title
// already recorded rather than blanking the row.
func TestPiReportedTitleWinsOverPaneTitle(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	// The pane title alone would render as "deploy - kido" once the pi
	// marker is stripped; the reported title must win instead.
	pane := h.piPane("alpha", "π - deploy - kido")

	h.agentStatus("pi-3", pane, "pi", "idle", "--title", "deploy")
	h.waitGlyph("deploy", "○")
	if got := h.rowFor("deploy"); got != "· ○ deploy" {
		t.Fatalf("row = %q, want the reported title alone, not the pane title", got)
	}

	// A later report with no --title keeps the title already recorded.
	h.agentStatus("pi-3", pane, "pi", "running")
	h.waitGlyph("deploy", "●")
	if got := h.rowFor("deploy"); got != "· ● deploy" {
		t.Fatalf("row = %q, want the earlier reported title kept", got)
	}
}

// TestPiBeatsClaudeOnTheSamePane checks the precedence rule. pi runs Claude
// Code inside its own pane (pi-claude-bridge, headless), and that Claude
// Code's hooks fire with pi's TMUX_PANE, so both agents write a record for
// the one pane. The pane is pi's, whichever wrote last.
func TestPiBeatsClaudeOnTheSamePane(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.piPane("alpha", "π - bridge - kido")

	// pi first, so its record is the older one: a most-recent-wins rule
	// would show the inner Claude Code's idle instead.
	h.agentStatus("pi-2", pane, "pi", "running")
	h.waitGlyph("bridge - kido", "●")
	h.hook("inner-claude", pane, "SessionStart") // idle
	// Long enough for ten ticks: the pi record must keep the pane, not
	// just win the race to be read first.
	time.Sleep(time.Second)
	if got := h.rowFor("bridge - kido"); got != "· ● bridge - kido" {
		t.Fatalf("row = %q, want pi's running record to hold the pane", got)
	}

	// And the other way round: pi's record is now the newer one, and the
	// inner Claude Code reporting again must not take the pane back.
	h.agentStatus("pi-2", pane, "pi", "waiting")
	h.waitGlyph("bridge - kido", "◆")
	h.hook("inner-claude", pane, "UserPromptSubmit") // running
	time.Sleep(time.Second)
	if got := h.rowFor("bridge - kido"); got != "· ◆ bridge - kido" {
		t.Fatalf("row = %q, want pi's waiting record to hold the pane", got)
	}

	// With pi gone, the inner record is all that is left and it shows.
	h.agentStatus("pi-2", pane, "pi", "", "--remove")
	h.waitGlyph("bridge - kido", "●")
}
