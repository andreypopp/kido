package e2e

import (
	"fmt"
	"strings"
	"testing"
)

// searchRows is the number of rows setupSearch's unfiltered list has.
const searchRows = 6

// searchLineOf returns the search prompt kido draws on the column's last
// line, or "".
func searchLineOf(lines []string) string {
	for _, l := range sidebarOf(lines) {
		if strings.HasPrefix(l, "/") {
			return l
		}
	}
	return ""
}

func (h *harness) searchLine() string { h.t.Helper(); return searchLineOf(h.capture()) }

func (h *harness) waitSearch(want string) {
	h.t.Helper()
	h.waitFor(func() bool { return h.searchLine() == want }, settle,
		func() string { return fmt.Sprintf("search prompt %q (is %q)", want, h.searchLine()) })
}

// waitSearchClosed waits until the prompt is gone and the full list (n
// rows) is back, reading both off one capture.
func (h *harness) waitSearchClosed(n int) {
	h.t.Helper()
	h.waitFor(func() bool {
		lines := h.capture()
		return searchLineOf(lines) == "" && len(rowsOf(lines)) == n
	}, settle, func() string {
		return fmt.Sprintf("search closed (prompt %q, %d rows, want %d)", h.searchLine(), len(h.rows()), n)
	})
}

func setupSearch(t *testing.T) *harness {
	h := start(t, "alpha")
	h.newSession("beta")
	h.newSession("gamma")
	h.waitRows(searchRows)
	focusSidebar(h)
	return h
}

// TestSearchFilters checks that "/" plus text fuzzy-filters the sessions.
func TestSearchFilters(t *testing.T) {
	t.Parallel()
	h := setupSearch(t)

	h.sendKeys("/")
	h.waitSearch("/")
	h.sendLiteral("bet")
	h.waitSearch("/bet")
	h.waitFor(func() bool {
		rows := h.rows()
		return len(rows) == 3 && rows[0] == "beta" // + pane row + prompt
	}, settle, msgf("only beta listed"))

	// Esc cancels: the full list comes back and the prompt goes away.
	h.sendKeys("Escape")
	h.waitSearchClosed(searchRows)
	if !h.clientFocused() {
		t.Error("Esc leaving the search also released the keyboard")
	}
}

// TestSearchBackspaceCloses checks Backspace erasing the last character
// and then closing the search.
func TestSearchBackspaceCloses(t *testing.T) {
	t.Parallel()
	h := setupSearch(t)

	h.sendKeys("/")
	h.sendLiteral("ga")
	h.waitSearch("/ga")
	h.sendKeys("BSpace")
	h.waitSearch("/g")
	h.sendKeys("BSpace")
	h.waitSearch("/")
	h.sendKeys("BSpace") // nothing left to erase: leave the search
	h.waitSearchClosed(searchRows)
	if !h.clientFocused() {
		t.Error("Backspace closing the search released the keyboard")
	}
}

// TestSearchEnterJumps checks that Enter in a filtered list jumps to the
// match and clears everything.
func TestSearchEnterJumps(t *testing.T) {
	t.Parallel()
	h := setupSearch(t)

	h.sendKeys("/")
	h.sendLiteral("gam")
	h.waitSearch("/gam")
	h.sendKeys("Enter")

	h.waitSession("gamma")
	h.waitFocused(false)
	h.waitSearchClosed(searchRows)
}

// TestSearchMatchesClaudeTitle checks that "/" also matches a session whose
// name does not contain the query but a Claude pane's title does: the
// session stays fully visible, and a session that matches neither drops out.
func TestSearchMatchesClaudeTitle(t *testing.T) {
	t.Parallel()
	h := start(t, "work")
	h.claudePane("work", "✳ Fix login redirect")
	h.newSession("chores")
	// work: header + its shell pane + its claude pane; chores: header + its
	// shell pane.
	h.waitRows(5)
	focusSidebar(h)

	h.sendKeys("/")
	h.sendLiteral("login")
	h.waitSearch("/login")
	h.waitFor(func() bool {
		rows := h.rows()
		// work's header, its two panes, and the search prompt.
		return len(rows) == 4 && rows[0] == "work" && hasLine(rows, "Fix login redirect")
	}, settle, func() string { return "only work (matched by pane title) listed: " + fmt.Sprint(h.rows()) })

	h.sendKeys("Escape")
	h.waitSearchClosed(5)
}

// TestSearchIgnoresSSHAndCommand checks that a query matching only an ssh
// destination or a plain command does not surface that session: only the
// session name and Claude pane titles are searched.
func TestSearchIgnoresSSHAndCommand(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.newWindow("alpha", "", "ssh", "-F", "/dev/null",
		"-o", "ProxyCommand="+h.sshProxy(), "deploy@example.test")
	h.waitPaneCommand(pane, "ssh")
	h.newSession("beta")
	h.newWindow("beta", "", "cat", "-")
	h.waitRow("· cat")
	focusSidebar(h)

	h.sendKeys("/")
	h.sendLiteral("example")
	h.waitSearch("/example")
	h.waitFor(func() bool { return len(h.rows()) == 1 }, settle, // just the prompt
		func() string { return "ssh host not searched, no sessions: " + fmt.Sprint(h.rows()) })
	h.sendKeys("Escape")
	h.waitSearchClosed(6)

	h.sendKeys("/")
	h.sendLiteral("cat")
	h.waitSearch("/cat")
	h.waitFor(func() bool { return len(h.rows()) == 1 }, settle, // just the prompt
		func() string { return "command not searched, no sessions: " + fmt.Sprint(h.rows()) })
	h.sendKeys("Escape")
	h.waitSearchClosed(6)
}
