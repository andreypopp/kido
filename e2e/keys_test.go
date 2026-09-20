package e2e

import (
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
		msgf("side-status off"))
	h.waitFor(func() bool { return !h.sidebarVisible() }, settle, msgf("sidebar gone"))
	if h.clientFocused() {
		t.Error("side-status-focus still set while the column is hidden")
	}

	h.prefix("K") // and back, with focus
	h.waitFor(func() bool { return h.in("show", "-gv", "side-status") == "left" }, settle,
		msgf("side-status left"))
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
	h.waitRows(6)
	focusSidebar(h)

	// Lines: 1 alpha, 2 ┌ shell, 3 └ shell, 4 beta, 5 ┌ shell, 6 └ shell.
	// The selection starts on alpha's active pane, line 2. Every pane row
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
	h.waitRows(5)
	focusSidebar(h)

	// Lines: 1 alpha, 2 · shell, 3 beta, 4 ┌ shell, 5 └ shell.
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
	h.waitRows(4)
	focusSidebar(h)

	h.sendKeys("G") // beta's pane
	h.waitSelected(shell)
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

// TestShiftUpDownSwitchesWindow checks that shift+up/down inside the sidebar
// call the same window-switching path as `kido switch-window`, without
// handing the keyboard back to the pane: the sidebar's own S-Up/S-Down keys
// would otherwise do nothing, since focused keys are routed to the side job
// and never reach the client-level bindings in tmux/kido-side.tmux.
func TestShiftUpDownSwitchesWindow(t *testing.T) {
	t.Parallel()
	h := setupSwitchWindowSessions(t) // sessions a, c, b (created order), each with two windows

	focusSidebar(h)
	h.waitWindow("a", "a0")

	// Lines: 1 a, 2 a0, 3 a1, 4 c, 5 c0, 6 c1, 7 b, 8 b0, 9 b1.
	h.waitSelectedLine(2)

	h.sendKeys("S-Down") // a0 -> a1, inside session a
	h.waitWindow("a", "a1")
	h.waitSelectedLine(3)
	if !h.clientFocused() {
		t.Fatal("shift+down released the sidebar's keyboard focus")
	}

	h.sendKeys("S-Down") // a1 -> c0, crossing into session c
	h.waitWindow("c", "c0")
	h.waitSelectedLine(5)
	if !h.clientFocused() {
		t.Fatal("shift+down released the sidebar's keyboard focus")
	}

	h.sendKeys("S-Up") // c0 -> a1, back across the session boundary
	h.waitWindow("a", "a1")
	h.waitSelectedLine(3)
	if !h.clientFocused() {
		t.Fatal("shift+up released the sidebar's keyboard focus")
	}
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
		msgf("a window created by prefix c (had %d panes)", before))
	if !h.clientFocused() {
		t.Error("the prefix command cleared side-status-focus")
	}
}
