package e2e

import (
	"fmt"
	"strings"
	"testing"
)

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

func TestPiPaneTitleAndNativeStatus(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	t.Run("identity removal preserves native status", func(t *testing.T) {
		t.Parallel()
		h := start(t, "alpha")
		pane := h.piPane("alpha", "π - deploy - kido")

		for _, c := range []struct{ state, glyph string }{
			{"idle", ""},
			{"working", "◼"},
			{"blocked", "◆"},
			{"working", "◼"},
		} {
			h.programStatus(pane, "state="+c.state+":app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", pane, "#{pane_title}"), "π - "))
			h.agentStatus("pi-1", pane)
			h.waitGlyph("deploy - kido", c.glyph)
		}

		// Removing identity does not clear the pane's terminal status.
		h.clearPiOptions(pane)
		h.waitFor(func() bool {
			return h.countRows("╶◼deploy - kido") == 0 && h.countRows("╶◼π - deploy - kido") == 1
		}, settle, func() string {
			return fmt.Sprintf("the bare pi pane retains its terminal status (rows are %q)", h.rows())
		})
	})

	t.Run("title and native status", func(t *testing.T) {
		pane := h.piPane("alpha", "π - deploy - branch - kido")
		h.programStatus(pane, "state=working:app=pi:msg=ZGVwbG95IC0gYnJhbmNo")
		h.agentStatus("pi-3", pane)
		h.waitGlyph("deploy - branch - kido", "◼")
		h.clearPiOptions(pane)
		h.waitRow("╶◼π - deploy - branch - kido")
		h.agentStatus("pi-3", pane)
		h.programStatus(pane, "state=clear")
		h.waitGlyph("node", "")
	})
}
