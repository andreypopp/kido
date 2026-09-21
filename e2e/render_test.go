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

// TestShellStatusRow drives a plain zsh pane through kido's OSC 133 shim
// (shell/zsh, installed by pointing ZDOTDIR at it) and expects the row to
// carry the same indicators an agent pane has: ○ at the prompt, ● while a
// command runs, ○ again when it is done.
func TestShellStatusRow(t *testing.T) {
	t.Parallel()
	if _, err := exec.LookPath("zsh"); err != nil {
		t.Skip("no zsh in PATH")
	}
	h := start(t, "alpha")

	shim, err := filepath.Abs(filepath.Join("..", "shell", "zsh"))
	if err != nil {
		t.Fatal(err)
	}
	// The ZDOTDIR the shim restores: an empty directory rather than the
	// developer's own, so the test never reads their rc files. The empty
	// .zshrc is what keeps zsh from opening its new-user setup wizard.
	home := filepath.Join(h.dir, "zdotdir")
	if err := os.MkdirAll(home, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, ".zshrc"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	// The one line a user adds to ~/.tmux.conf, with the paths filled in.
	h.in("set-option", "-g", "default-command",
		fmt.Sprintf("KIDO_ZDOTDIR=%q ZDOTDIR=%q exec zsh", home, shim))

	// No argv, so the pane runs default-command: zsh through the shim.
	pane := h.newWindow("alpha", "")
	h.waitPaneCommand(pane, "zsh")
	h.waitRow("○ zsh")

	h.in("send-keys", "-t", pane, "sleep 5", "Enter")
	h.waitPaneCommand(pane, "sleep")
	h.waitRow("● sleep")

	h.waitFor(func() bool { return hasLine(h.sidebar(), "○ zsh") },
		10*time.Second, msgf("the row back at ○ zsh after the sleep"))
}
