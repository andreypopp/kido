package e2e

import (
	"testing"

	"github.com/charmbracelet/x/ansi"
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

// Every route into and out of sidebar focus, on one server: prefix k,
// Escape and C-c, C-s, a prefix command reaching the pane, and a mouse
// click in the pane.
func TestSidebarFocusToggles(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	if h.clientFocused() {
		t.Fatal("the sidebar has focus before the test starts")
	}

	h.prefix("k")
	h.waitFocused(true)
	h.prefix("k")
	h.waitFocused(false)

	focusSidebar(h)
	h.sendKeys("Escape")
	h.waitFocused(false)
	focusSidebar(h)
	h.sendKeys("C-c")
	h.waitFocused(false)

	h.sendKeys("C-s")
	h.waitFocused(true)
	h.sendKeys("C-s")
	h.waitFocused(false)

	focusSidebar(h)
	before := len(h.panes())
	h.prefix("c") // new window in the client's session
	h.waitFor(func() bool { return len(h.panes()) == before+1 }, settle,
		msgf("a window created by prefix c (had %d panes)", before))
	if !h.clientFocused() {
		t.Error("the prefix command cleared side-status-focus")
	}

	h.click(sideWidth+20, 5)
	h.waitFocused(false)
}

// Movement, first/last and Enter on one six-row layout: two sessions,
// one with a split, so headers are stepped over rather than selected.
func TestSidebarMotionKeys(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.in("split-window", "-d", "-t", "alpha:")
	h.newSession("beta")
	h.in("split-window", "-d", "-t", "beta:")
	h.waitRows(6)
	focusSidebar(h)

	// Lines: 1 alpha, 2 ┌ shell, 3 └ shell, 4 beta, 5 ┌ shell, 6 └ shell.
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

	h.sendKeys("G")
	h.waitSelectedLine(6)
	h.sendKeys("g")
	h.sendKeys("g")
	h.waitSelectedLine(2)

	h.sendKeys("G")
	h.waitSelected(shell)
	h.sendKeys("Enter")
	h.waitSession("beta")
	h.waitFocused(false)
}

// TestCtrlSOpensPickerWithSidebarHidden checks that, with the sidebar
// hidden, C-s opens kido's one-shot picker in a popup, and that q closes
// it again. The popup runs a literal "tmux" (share/tmux/kido-tmux.conf), which
// resolves through serverPathPrefix (start, via requireTmux, already
// skips when there is no patched tmux to put there) rather than through
// the share/bin/tmux shim a real install has - see setup().
func TestCtrlSOpensPickerWithSidebarHidden(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.prefix("K") // hide the sidebar
	h.waitFor(func() bool { return !h.sidebarVisible() }, settle, msgf("sidebar gone"))

	h.sendKeys("C-s")
	h.waitFor(func() bool { return hasLine(outerScreenLines(h), "alpha") }, settle,
		msgf("the popup picker showing session alpha"))

	h.sendKeys("q")
	h.waitFor(func() bool { return !hasLine(outerScreenLines(h), "alpha") }, settle,
		msgf("the popup picker closed"))
}

// outerScreenLines, unlike h.sidebar(), keeps the window area: a popup
// draws over it too.
func outerScreenLines(h *harness) []string {
	h.t.Helper()
	out := make([]string, 0, len(h.capture()))
	for _, l := range h.capture() {
		out = append(out, ansi.Strip(l))
	}
	return out
}
