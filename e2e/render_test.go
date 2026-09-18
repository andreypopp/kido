package e2e

import (
	"os"
	"path/filepath"
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
	h.waitFor(func() bool { return len(h.rows()) >= 6 }, settle, "all rows")

	rows := h.rows()
	want := []string{"zeta", "· " + h.shell, "alpha",
		"┌ " + h.shell, "├ " + h.shell, "└ " + h.shell}
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
	h.in("new-window", "-d", "-t", "beta:", "-n", "editor", "cat")
	h.waitRow("· cat")

	h.waitSelected(h.shell)
	h.in("switch-client", "-c", h.client, "-t", "beta:1")
	h.waitSession("beta")

	h.waitSelected("cat")
	h.waitFor(func() bool { return h.selectedIndex() == h.rowIndex("· cat") }, settle,
		"selection on the cat row")
}

// TestSSHRow shows a pane running ssh by its destination.
func TestSSHRow(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	// ssh blocks on the proxy command, so no network is needed. The proxy
	// is a script rather than "sleep 300" because kido reads ssh's
	// arguments out of ps output, where a space inside an option value is
	// indistinguishable from an argument separator.
	proxy := filepath.Join(h.dir, "proxy")
	if err := os.WriteFile(proxy, []byte("#!/bin/sh\nexec sleep 300\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	pane := h.in("new-window", "-P", "-F", "#{pane_id}", "-d", "-t", "alpha:")
	// ssh must be a child of the pane's shell: kido keys the destination
	// by the ssh process's ppid.
	h.in("send-keys", "-t", pane,
		"ssh -F /dev/null -o ProxyCommand="+proxy+" deploy@example.test", "Enter")
	h.waitFor(func() bool {
		for _, p := range h.panes() {
			if p.ID == pane && p.Command == "ssh" {
				return true
			}
		}
		return false
	}, settle, "pane running ssh")
	h.waitRow("ssh deploy@example.test")
}

// TestSSHRowDirect shows a pane whose command is ssh itself (e.g. `tmux
// new-window 'ssh host'`), not a shell that then ran ssh: the pane's root
// process is ssh, so kido must key the destination by ssh's own pid too.
func TestSSHRowDirect(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	proxy := filepath.Join(h.dir, "proxy")
	if err := os.WriteFile(proxy, []byte("#!/bin/sh\nexec sleep 300\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	// Passing the command as separate arguments (rather than one quoted
	// string) makes tmux run it directly with execvp, with no shell in
	// between: the pane's root process is ssh itself.
	pane := h.in("new-window", "-P", "-F", "#{pane_id}", "-d", "-t", "alpha:",
		"ssh", "-F", "/dev/null", "-o", "ProxyCommand="+proxy, "deploy@example.test")
	h.waitFor(func() bool {
		for _, p := range h.panes() {
			if p.ID == pane && p.Command == "ssh" {
				return true
			}
		}
		return false
	}, settle, "pane running ssh")
	h.waitRow("ssh deploy@example.test")
}
