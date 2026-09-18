package e2e

import (
	"fmt"
	"strconv"
	"strings"
	"testing"
)

// TestMouseClickJumps checks that clicking a row switches the client to
// that pane and gives the keyboard back to it.
func TestMouseClickJumps(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.newSession("beta")
	h.waitFor(func() bool { return len(h.rows()) == 4 }, settle, "4 rows")

	y := h.rowIndex("beta") + 1 // beta's pane row, right under its header
	h.click(5, y)

	h.waitSession("beta")
	h.waitFocused(false)
}

// TestMouseClickInPaneReleasesFocus checks that a click in the window area
// takes the keyboard away from the sidebar.
func TestMouseClickInPaneReleasesFocus(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	focusSidebar(h)
	h.click(sideWidth+20, 5)
	h.waitFocused(false)
}

// TestMouseWheelScrolls checks the wheel moves a list longer than the
// column.
func TestMouseWheelScrolls(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	for i := 0; i < 40; i++ {
		h.in("new-session", "-d", "-s", fmt.Sprintf("s%02d", i), "-c", h.dir)
	}
	// The list is far longer than the column, so the last sessions are off
	// screen until the wheel scrolls to them.
	h.waitFor(func() bool { return len(h.panes()) == 41 }, settle, "41 panes")
	h.waitFor(func() bool { return len(h.rows()) >= outerRows-2 }, settle, "a full column")

	first := h.sidebar()[0]
	for i := 0; i < 4; i++ {
		h.wheelDown(5, 10)
	}
	h.waitFor(func() bool { return h.sidebar()[0] != first }, settle,
		"the list scrolled down from "+strconv.Quote(first))
	scrolled := h.sidebar()[0]

	for i := 0; i < 6; i++ {
		h.wheelUp(5, 10)
	}
	h.waitFor(func() bool { return h.sidebar()[0] == first }, settle,
		"the list scrolled back up from "+strconv.Quote(scrolled))
}

// TestMouseDragResizes checks that dragging the separator changes the
// global side-status-width.
func TestMouseDragResizes(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	if got := h.in("show", "-gv", "side-status-width"); got != strconv.Itoa(sideWidth) {
		t.Fatalf("side-status-width = %s, want %d", got, sideWidth)
	}

	h.drag(sideWidth, sideWidth+20, 10)

	h.waitFor(func() bool {
		w, _ := strconv.Atoi(h.in("show", "-gv", "side-status-width"))
		return w > sideWidth+10
	}, settle, "side-status-width grew (is "+h.in("show", "-gv", "side-status-width")+")")

	// The column really is wider on screen.
	w, _ := strconv.Atoi(h.in("show", "-gv", "side-status-width"))
	h.waitFor(func() bool {
		for _, line := range h.capture() {
			r := []rune(stripANSI(line))
			if len(r) >= w && r[w-1] == '│' {
				return true
			}
		}
		return false
	}, settle, "the separator moved to column "+strconv.Itoa(w))
	if !strings.Contains(strings.Join(h.rows(), "\n"), "alpha") {
		t.Error("the sidebar lost its content after the resize")
	}
}
