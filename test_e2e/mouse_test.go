package e2e

import (
	"fmt"
	"strconv"
	"strings"
	"testing"
)

func TestMouseClickJumps(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.newSession("beta")
	h.waitRows(4)

	y := h.rowIndex("beta") + 1 // beta's pane row, right under its header
	h.click(5, y)

	h.waitSession("beta")
	h.waitFocused(false)
}

func TestMouseWheelScrolls(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	// One tmux invocation for all 40: the sessions are only scenery, and
	// 40 round trips to the server are not.
	var args []string
	for i := 0; i < 40; i++ {
		if len(args) > 0 {
			args = append(args, ";")
		}
		args = append(args, "new-session", "-d", "-s", fmt.Sprintf("s%02d", i), "-c", h.dir)
	}
	h.in(args...)
	// The list is far longer than the column, so the last sessions are off
	// screen until the wheel scrolls to them.
	h.waitFor(func() bool { return len(h.panes()) == 41 }, settle, msgf("41 panes"))
	h.waitFor(func() bool { return len(h.rows()) >= outerRows-2 }, settle, msgf("a full column"))

	first := h.sidebar()[0]
	for i := 0; i < 4; i++ {
		h.wheelDown(5, 10)
	}
	h.waitFor(func() bool { return h.sidebar()[0] != first }, settle,
		msgf("the list scrolled down from %q", first))
	scrolled := h.sidebar()[0]

	for i := 0; i < 6; i++ {
		h.wheelUp(5, 10)
	}
	h.waitFor(func() bool { return h.sidebar()[0] == first }, settle,
		msgf("the list scrolled back up from %q", scrolled))
}

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
	}, settle, func() string {
		return "side-status-width grew (is " + h.in("show", "-gv", "side-status-width") + ")"
	})

	// The column really is wider on screen.
	w, _ := strconv.Atoi(h.in("show", "-gv", "side-status-width"))
	h.waitFor(func() bool { return h.separatorAt(w) }, settle,
		msgf("the separator moved to column %d", w))
	if !strings.Contains(strings.Join(h.rows(), "\n"), "alpha") {
		t.Error("the sidebar lost its content after the resize")
	}

	// Shrinking starts on the same edge, but the first drag sample is
	// already inside the job, which must not eat it.
	h.drag(w, w-10, 10)
	h.waitFor(func() bool {
		now, _ := strconv.Atoi(h.in("show", "-gv", "side-status-width"))
		return now < w
	}, settle, func() string {
		return "side-status-width shrank from " + strconv.Itoa(w) + " (is " + h.in("show", "-gv", "side-status-width") + ")"
	})
	shrunk, _ := strconv.Atoi(h.in("show", "-gv", "side-status-width"))

	h.doubleClick(shrunk, 10)
	h.waitFor(func() bool { return h.in("show", "-gv", "side-status-width") == strconv.Itoa(sideWidth) },
		settle, func() string {
			return "double-click restored side-status-width (is " + h.in("show", "-gv", "side-status-width") + ")"
		})

	// On the right side the line is at the left of the side column, so a
	// shrink drag moves right and its samples are inside the job.
	h.in("set", "-g", "side-status", "right")
	cw, _ := strconv.Atoi(h.in("display-message", "-p", "#{client_width}"))
	sep := cw - sideWidth + 1
	h.waitFor(func() bool { return h.separatorAt(sep) }, settle, msgf("the right separator at column %d", sep))
	h.drag(sep, sep+10, 10)
	h.waitFor(func() bool {
		now, _ := strconv.Atoi(h.in("show", "-gv", "side-status-width"))
		return now < sideWidth
	}, settle, func() string {
		return "the right side shrank (is " + h.in("show", "-gv", "side-status-width") + ")"
	})
	shrunk, _ = strconv.Atoi(h.in("show", "-gv", "side-status-width"))
	sep = cw - shrunk + 1
	h.waitFor(func() bool { return h.separatorAt(sep) }, settle, msgf("the right separator moved to column %d", sep))
}
