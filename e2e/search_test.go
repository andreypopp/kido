package e2e

import (
	"fmt"
	"strings"
	"testing"
)

// searchRows is the number of rows setupSearch's unfiltered list has.
const searchRows = 6

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

// "/" also matches a session whose name does not contain the query but a
// Claude pane's title does: the session stays fully visible.
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

// Only the session name, agent titles, and ssh destinations are
// searched: a query matching an ssh pane's destination (user or host
// part) surfaces its session, one matching only a plain foreground
// command does not.
func TestSearchMatchesSSHDestinationNotCommand(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.newWindow("alpha", "", "ssh", "-F", "/dev/null",
		"-o", "ProxyCommand="+h.sshProxy(), "deploy@example.test")
	h.waitPaneCommand(pane, "ssh")
	h.newSession("beta")
	h.newWindow("beta", "", "cat", "-")
	h.waitRow("╶  cat")
	focusSidebar(h)

	h.sendKeys("/")
	h.sendLiteral("example")
	h.waitSearch("/example")
	h.waitFor(func() bool {
		rows := h.rows()
		return len(rows) == 4 && rows[0] == "alpha" // + 2 panes + prompt
	}, settle, func() string { return "ssh host searched, only alpha listed: " + fmt.Sprint(h.rows()) })
	h.sendKeys("Escape")
	h.waitSearchClosed(6)

	h.sendKeys("/")
	h.sendLiteral("deploy")
	h.waitSearch("/deploy")
	h.waitFor(func() bool {
		rows := h.rows()
		return len(rows) == 4 && rows[0] == "alpha" // + 2 panes + prompt
	}, settle, func() string { return "ssh user searched, only alpha listed: " + fmt.Sprint(h.rows()) })
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
