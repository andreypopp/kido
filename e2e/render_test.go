package e2e

import (
	"fmt"
	"os"
	"os/exec"
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

// TestShellStatusRow drives a plain zsh pane through kido's OSC 133
// integration (shell/zsh/integration.zsh, sourced from a .zshrc the way
// `kido setup-zsh` arranges) and expects the row to carry the same
// indicators an agent pane has: an empty two-column field at the prompt,
// a green ▌ while a command runs, and a red ▌ once a command has exited
// nonzero, until the pane is visited.
func TestShellStatusRow(t *testing.T) {
	t.Parallel()
	zsh, err := exec.LookPath("zsh")
	if err != nil {
		t.Skip("no zsh in PATH")
	}
	h := start(t, "alpha")

	// The pane the client starts on, to come back to: a visited pane is
	// the selected row, which kido draws with its colours stripped, so the
	// colour checks below only mean something from somewhere else.
	home := ""
	for _, p := range h.panes() {
		if p.Session == "alpha" && p.Active {
			home = p.ID
		}
	}
	if home == "" {
		t.Fatal("no active pane in alpha")
	}

	script, err := filepath.Abs(filepath.Join("..", "shell", "zsh", "integration.zsh"))
	if err != nil {
		t.Fatal(err)
	}
	// A ZDOTDIR of our own rather than the developer's home, so the test
	// never reads their rc files, holding the source line setup-zsh's
	// block carries.
	zdot := filepath.Join(h.dir, "zdotdir")
	if err := os.MkdirAll(zdot, 0o755); err != nil {
		t.Fatal(err)
	}
	rc := fmt.Sprintf("source %q\n", script)
	if err := os.WriteFile(filepath.Join(zdot, ".zshrc"), []byte(rc), 0o644); err != nil {
		t.Fatal(err)
	}
	h.in("set-environment", "-g", "ZDOTDIR", zdot)
	// tmux starts its own default shell (the harness's config sets bash),
	// with no default-command in sight.
	h.in("set-option", "-g", "default-shell", zsh)

	// No argv, so the pane runs the default shell, which reads the .zshrc
	// above.
	pane := h.newWindow("alpha", "")
	h.waitPaneCommand(pane, "zsh")
	// An idle integrated shell shows nothing, in a field that keeps the
	// label at the column every other row starts at.
	h.waitZshRow("·   zsh", false)

	h.in("send-keys", "-t", pane, "sleep 5", "Enter")
	h.waitPaneCommand(pane, "sleep")
	h.waitZshRow("· ▌ sleep", false)

	h.waitFor(func() bool { return h.zshRow("·   zsh", false) },
		10*time.Second, msgf("the row back at an empty indicator after the sleep"))

	// A command that fails leaves the row red until the pane is visited.
	h.in("send-keys", "-t", pane, "false", "Enter")
	h.waitZshRow("· ▌ zsh", true)

	// Visiting the pane clears it: the failure is older than the visit.
	h.in("select-window", "-t", pane)
	h.in("select-pane", "-t", pane)
	h.waitSelected("zsh")
	h.in("select-window", "-t", home)
	h.in("select-pane", "-t", home)
	h.waitZshRow("·   zsh", false)
}

// zshRow reports whether the sidebar holds exactly the row want, with (or
// without) a red foreground on it. Text and colour are read from one
// capture, so a row cannot be matched in one frame and coloured in
// another.
func (h *harness) zshRow(want string, red bool) bool {
	h.t.Helper()
	for _, line := range h.capture() {
		if sideText(line) == want {
			return hasSGR(sideOf(line), "31") == red
		}
	}
	return false
}

func (h *harness) waitZshRow(want string, red bool) {
	h.t.Helper()
	h.waitFor(func() bool { return h.zshRow(want, red) }, settle, func() string {
		return fmt.Sprintf("row %q (red=%v); rows are %q", want, red, h.rows())
	})
}
