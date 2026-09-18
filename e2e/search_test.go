package e2e

import (
	"strings"
	"testing"
)

// searchLine returns the search prompt kido draws on the column's last
// line, or "".
func (h *harness) searchLine() string {
	h.t.Helper()
	for _, l := range h.sidebar() {
		if strings.HasPrefix(l, "/") {
			return l
		}
	}
	return ""
}

func (h *harness) waitSearch(want string) {
	h.t.Helper()
	h.waitFor(func() bool { return h.searchLine() == want }, settle,
		"search prompt "+want+" (is "+h.searchLine()+")")
}

func setupSearch(t *testing.T) *harness {
	h := start(t, "alpha")
	h.newSession("beta")
	h.newSession("gamma")
	h.waitFor(func() bool { return len(h.rows()) == 6 }, settle, "6 rows")
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
		return len(rows) == 3 && strings.TrimSpace(rows[0]) == "beta" // + pane row + prompt
	}, settle, "only beta listed")

	// Esc cancels: the full list comes back and the prompt goes away.
	h.sendKeys("Escape")
	h.waitFor(func() bool { return h.searchLine() == "" && len(h.rows()) == 6 }, settle,
		"filter cleared")
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
	h.waitFor(func() bool { return h.searchLine() == "" && len(h.rows()) == 6 }, settle,
		"search closed")
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
	h.waitFor(func() bool { return h.searchLine() == "" && len(h.rows()) == 6 }, settle,
		"list restored after the jump")
}
