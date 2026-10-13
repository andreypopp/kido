package e2e

import (
	"os/exec"
	"strings"
	"testing"
)

// openPopup opens a popup on the inner client, left standing until the
// test ends: the CLI's display-popup returns only once the popup closes.
func openPopup(h *harness) {
	h.t.Helper()
	popup := exec.Command(tmuxBin, "-S", h.inner, "display-popup", "-c", h.client, "-E", "sleep 300")
	popup.Env = cleanEnv("TMUX=")
	if err := popup.Start(); err != nil {
		h.t.Fatal(err)
	}
	h.t.Cleanup(func() { _ = popup.Process.Kill(); _ = popup.Wait() })
	h.waitFor(func() bool {
		return strings.Contains(h.in("list-panes", "-a", "-F", "#{pane_modal_flag}"), "1")
	}, settle, msgf("the popup's pane"))
}

// A popup is not a sidebar row and does not move its selection. The beta
// session confirms that the sidebar polls with the popup open; without it,
// the assertions could run before the sidebar sees the popup.
func TestSidebarIgnoresAPopup(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.in("split-window", "-d", "-t", "alpha:")
	h.waitRows(3)
	h.waitSelectedLine(2)

	openPopup(h)

	h.newSession("beta")

	if rows := h.rows(); len(rows) != 5 || hasLine(rows, "sleep") {
		t.Fatalf("rows with a popup open: %q, want alpha's two panes and beta's one, no popup", rows)
	}
	if n := h.selectedIndex(); n != 2 {
		t.Fatalf("selection on line %d with a popup open, want 2 (%q)", n, h.selectedRow())
	}
}

// An RPC feed started while a popup stands reports the pane under the
// popup as its client's: that is a picker's own case, run inside the
// popup it opened. With the popup's pane dropped and nothing active in its
// place, the feed would know no client pane.
func TestSidebarFeedDrawsUnderAPopup(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	under := h.in("display-message", "-p", "-t", "alpha:", "#{pane_id}")
	h.in("split-window", "-d", "-t", "alpha:")
	h.waitRows(3)

	openPopup(h)

	h.startFeed("alpha").waitLast(func(s feedSnapshot) bool { return s.Client.Pane == under },
		"the client's pane under the popup")
}
