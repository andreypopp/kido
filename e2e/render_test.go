package e2e

import (
	"strings"
	"testing"
	"time"
)

// TestRenderGrouping checks the shape of the list: sessions oldest first,
// the client's session bold, window grouping glyphs, and process names.
func TestRenderGrouping(t *testing.T) {
	t.Parallel()
	h := start(t, "zeta")

	// session_created has one-second resolution and ties break by name, so
	// let the first session age before creating the second.
	time.Sleep(1200 * time.Millisecond)
	h.newSession("alpha")
	h.in("split-window", "-d", "-t", "alpha:")
	h.in("split-window", "-d", "-t", "alpha:")
	h.waitFor(func() bool { return len(h.rows()) >= 6 }, settle, msgf("all rows"))

	rows := h.rows()
	want := []string{"zeta", "· " + shell, "alpha",
		"┌ " + shell, "├ " + shell, "└ " + shell}
	if len(rows) != len(want) {
		t.Fatalf("rows = %q, want %q", rows, want)
	}
	for i, w := range want {
		if strings.TrimSpace(rows[i]) != w {
			t.Errorf("row %d = %q, want %q", i, rows[i], w)
		}
	}

	// The client is attached to zeta, which is created first: it is bold
	// and alpha is not.
	if !h.isBold("zeta") {
		t.Error("current session zeta is not bold")
	}
	if h.isBold("alpha") {
		t.Error("alpha is bold but is not the client's session")
	}
}

// TestFollowActivePane moves the client to another session and expects the
// selection to follow the new active pane.
func TestFollowActivePane(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.newSession("beta")
	// "cat" waits on stdin, so this window's row reads differently from
	// every shell row and the selection is unambiguous.
	h.newWindow("beta", "editor", "cat", "-")
	h.waitRow("· cat")

	h.waitSelected(shell)
	h.in("switch-client", "-c", h.client, "-t", "beta:1")
	h.waitSession("beta")

	h.waitSelected("cat")
	h.waitFor(func() bool {
		lines := h.capture()
		return selectedIndexOf(lines) == rowIndexOf(lines, "· cat")
	}, settle, msgf("selection on the cat row"))
}

// TestActiveWindowBold bolds every row of the window the client is
// currently on, and moves the bold when the client switches windows within
// the same session; a window the client is not on stays unbold even though
// it is in the same session.
//
// The active pane of the current window is also the selected row, whose
// reverse video strips every inner style (see View in internal/ui/ui.go),
// bold included - so bold can only be observed on a row that is not
// selected. Each window here gets a second, non-active pane for exactly
// that: a bold check that reverse video cannot mask. Every pane runs a
// distinct foreground command so isBold's substring match is unambiguous.
func TestActiveWindowBold(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha") // window 0: pane 0 is the shell, active

	// cat and sleep block on their own, so they stay the foreground
	// command; -d keeps the new pane out of focus, so the shell (window 0)
	// and tail (window 1) stay the active panes of their windows.
	h.in("split-window", "-d", "-t", "alpha:", "cat", "-")
	h.newWindow("alpha", "editor", "tail", "-f", "/dev/null")
	h.in("split-window", "-d", "-t", "alpha:editor", "sleep", "300")
	h.waitRow("cat")
	h.waitRow("tail")
	h.waitRow("sleep")

	// The client starts on window 0: its non-active pane (cat) is bold,
	// window 1's non-active pane (sleep) is not.
	h.waitFor(func() bool { return h.isBold("cat") }, settle,
		msgf("window 0's cat row is bold"))
	if h.isBold("tail") {
		t.Error("tail row is bold but window 1 is not the client's current window")
	}
	if h.isBold("sleep") {
		t.Error("sleep row is bold but window 1 is not the client's current window")
	}

	h.in("select-window", "-t", "alpha:editor")
	h.waitFor(func() bool { return h.isBold("sleep") }, settle,
		msgf("window 1's sleep row is bold after switching to it"))
	if h.isBold("cat") {
		t.Error("cat row is still bold after the client left window 0")
	}
	if h.isBold(shell) {
		t.Error("shell row is bold but is not in the client's current window")
	}
}

// TestSSHRow shows a pane running ssh by its destination.
func TestSSHRow(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	// ssh blocks on the proxy command, so no network is needed.
	pane := h.newWindow("alpha", "")
	// ssh must be a child of the pane's shell: kido keys the destination
	// by the ssh process's ppid.
	h.in("send-keys", "-t", pane,
		"ssh -F /dev/null -o ProxyCommand="+h.sshProxy()+" deploy@example.test", "Enter")
	h.waitPaneCommand(pane, "ssh")
	h.waitRow("ssh deploy@example.test")
}

// TestSSHRowDirect shows a pane whose command is ssh itself (e.g. `tmux
// new-window 'ssh host'`), not a shell that then ran ssh: the pane's root
// process is ssh, so kido must key the destination by ssh's own pid too.
func TestSSHRowDirect(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	// newWindow passes the command as separate arguments, so tmux runs it
	// directly with execvp and the pane's root process is ssh itself.
	pane := h.newWindow("alpha", "", "ssh", "-F", "/dev/null",
		"-o", "ProxyCommand="+h.sshProxy(), "deploy@example.test")
	h.waitPaneCommand(pane, "ssh")
	h.waitRow("ssh deploy@example.test")
}
