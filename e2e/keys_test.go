package e2e

import (
	"strconv"
	"testing"
)

// focusSidebar gives the sidebar the keyboard (prefix k) and waits.
func focusSidebar(h *harness) {
	h.t.Helper()
	h.prefix("k")
	h.waitFocused(true)
}

// TestPrefixKShowHide checks that prefix K hides the column and brings it
// back with keyboard focus.
func TestPrefixKShowHide(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	focusSidebar(h)
	h.prefix("K") // the column is on: K hides it
	h.waitFor(func() bool { return h.in("show", "-gv", "side-status") == "off" }, settle,
		"side-status off")
	h.waitFor(func() bool { return !h.sidebarVisible() }, settle, "sidebar gone")
	if h.clientFocused() {
		t.Error("side-status-focus still set while the column is hidden")
	}

	h.prefix("K") // and back, with focus
	h.waitFor(func() bool { return h.in("show", "-gv", "side-status") == "left" }, settle,
		"side-status left")
	h.waitRow("alpha")
	h.waitFocused(true)
}

// TestPrefixKToggleFocus checks prefix k both ways.
func TestPrefixKToggleFocus(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	if h.clientFocused() {
		t.Fatal("the sidebar has focus before prefix k")
	}
	h.prefix("k")
	h.waitFocused(true)
	h.prefix("k")
	h.waitFocused(false)
}

// TestMotionKeys walks the list with every movement key.
func TestMotionKeys(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.in("split-window", "-d", "-t", "alpha:")
	h.newSession("beta")
	h.in("split-window", "-d", "-t", "beta:")
	h.waitFor(func() bool { return len(h.rows()) == 6 }, settle, "6 rows")
	focusSidebar(h)

	// Lines: 1 alpha, 2 ┌ zsh, 3 └ zsh, 4 beta, 5 ┌ zsh, 6 └ zsh. The
	// selection starts on alpha's active pane, line 2. Every pane row
	// reads the same, so assert the line, not the text.
	h.waitSelectedLine(2)
	for _, c := range []struct {
		key  string
		want int
	}{
		{"j", 3},
		{"j", 5}, // into beta, skipping the session header
		{"k", 3},
		{"C-n", 5},
		{"C-p", 3},
		{"C-j", 5},
		{"C-k", 3},
	} {
		h.sendKeys(c.key)
		h.waitSelectedLine(c.want)
	}
}

// TestFirstLastKeys checks gg and G.
func TestFirstLastKeys(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.newSession("beta")
	h.in("split-window", "-d", "-t", "beta:")
	h.waitFor(func() bool { return len(h.rows()) == 5 }, settle, "5 rows")
	focusSidebar(h)

	// Lines: 1 alpha, 2 · zsh, 3 beta, 4 ┌ zsh, 5 └ zsh.
	h.sendKeys("G")
	h.waitSelectedLine(5)

	h.sendKeys("g")
	h.sendKeys("g")
	h.waitSelectedLine(2)
}

// TestEnterJumps moves the client to the selected pane and hands the
// keyboard back.
func TestEnterJumps(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.newSession("beta")
	h.waitFor(func() bool { return len(h.rows()) == 4 }, settle, "4 rows")
	focusSidebar(h)

	h.sendKeys("G") // beta's pane
	h.waitSelected("zsh")
	h.sendKeys("Enter")

	h.waitSession("beta")
	h.waitFocused(false)
}

// TestEscReleasesFocus checks Esc hands the keyboard back to the pane.
func TestEscReleasesFocus(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	focusSidebar(h)
	h.sendKeys("Escape")
	h.waitFocused(false)

	focusSidebar(h)
	h.sendKeys("C-c")
	h.waitFocused(false)
}

// TestPrefixPassthrough checks that the prefix still reaches tmux while
// the sidebar holds the keyboard.
func TestPrefixPassthrough(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	focusSidebar(h)
	before := len(h.panes())

	h.prefix("c") // new window in the client's session
	h.waitFor(func() bool { return len(h.panes()) == before+1 }, settle,
		"a window created by prefix c (had "+strconv.Itoa(before)+" panes)")
	if !h.clientFocused() {
		t.Error("the prefix command cleared side-status-focus")
	}
}
