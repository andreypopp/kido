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

// waitSearchClosed waits until the prompt is gone and the full list is
// back, reading both off one capture.
func (h *harness) waitSearchClosed() {
	h.t.Helper()
	h.waitFor(func() bool {
		lines := h.capture()
		return searchLineOf(lines) == "" && len(rowsOf(lines)) == searchRows
	}, settle, func() string {
		return fmt.Sprintf("search closed (prompt %q, %d rows)", h.searchLine(), len(h.rows()))
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
	h.waitSearchClosed()
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
	h.waitSearchClosed()
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
	h.waitSearchClosed()
}
