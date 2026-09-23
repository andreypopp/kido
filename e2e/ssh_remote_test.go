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

// sshOpts are passed both to the reachability probe and to the pane's own
// ssh, so the two agree about what "localhost is reachable" meant.
var sshOpts = []string{
	"-o", "BatchMode=yes",
	"-o", "ConnectTimeout=5",
	"-o", "StrictHostKeyChecking=accept-new",
}

// requireLocalSSH skips unless an unattended ssh to localhost works.
// Unlike the patched tmux this is never required: a machine with no sshd,
// or none the user can log into without a password, is an ordinary place
// to run the suite and KIDO_E2E_REQUIRED says nothing about it.
func requireLocalSSH(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("ssh"); err != nil {
		t.Skip("no ssh in PATH")
	}
	cmd := exec.Command("ssh", append(append([]string{}, sshOpts...), "localhost", "true")...)
	cmd.Env = cleanEnv()
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Skipf("no unattended ssh to localhost: %v\n%s", err, out)
	}
}

// TestSSHRemoteShellStatus drives a real ssh to localhost whose remote
// shell carries kido's OSC 133 integration, and expects the row to report
// the remote shell's commands: tmux parses the markers off the local
// pane's output stream however far away they were written.
//
// The destination is still the label - the remote status is added to it,
// not in place of it.
func TestSSHRemoteShellStatus(t *testing.T) {
	t.Parallel()
	zsh, err := exec.LookPath("zsh")
	if err != nil {
		t.Skip("no zsh in PATH")
	}
	requireLocalSSH(t)
	h := start(t, "alpha")

	script, err := filepath.Abs(filepath.Join("..", "shell", "zsh", "integration.zsh"))
	if err != nil {
		t.Fatal(err)
	}
	// One ZDOTDIR for both ends: localhost is the same filesystem and the
	// same user, and the local shell needs the integration as much as the
	// remote one does - the gate is a remote prompt marked after the
	// local shell marked ssh as started.
	zdot := filepath.Join(h.dir, "zdotdir")
	if err := os.MkdirAll(zdot, 0o755); err != nil {
		t.Fatal(err)
	}
	rc := fmt.Sprintf("source %q\nPS1='remote%% '\n", script)
	if err := os.WriteFile(filepath.Join(zdot, ".zshrc"), []byte(rc), 0o644); err != nil {
		t.Fatal(err)
	}
	h.in("set-environment", "-g", "ZDOTDIR", zdot)
	h.in("set-option", "-g", "default-shell", zsh)

	pane := h.newWindow("alpha", "")
	h.waitPaneCommand(pane, "zsh")
	h.waitZshRow("╶  zsh", "")

	// ssh is a child of the pane's shell, and forces a pty for a remote
	// command that is itself an interactive shell - which is what makes
	// this the pane kido used to suppress wholesale. ZDOTDIR is spelled
	// out in the remote command because ssh forwards no environment.
	h.in("send-keys", "-t", pane, fmt.Sprintf("ssh -tt %s localhost %q",
		strings.Join(sshOpts, " "), "ZDOTDIR="+zdot+" exec "+zsh+" -i"), "Enter")
	h.waitPaneCommand(pane, "ssh")
	// Whether a running row also names the command the far side is
	// running depends on the tmux under test: one without the
	// pane_command_line patch expands the name to empty. The local shell
	// has just marked this ssh as started with kido's own integration, so
	// its command line is there to read on a tmux that keeps one.
	withCmd := h.in("display-message", "-p", "-t", pane, "#{pane_command_line}") != ""
	running := func(row, cmd string) string {
		if withCmd {
			return row + ": " + cmd
		}
		return row
	}
	// The far side has reached a prompt: the row is an idle integrated
	// shell's, in the field, and still names the destination.
	h.waitZshRow("╶  ssh localhost", "")

	// A first remote command, whose exit status crossing the connection is
	// the first thing here that a suppressed ssh pane could not show.
	//
	// It is also what the gate needs: over a loopback connection the
	// prompt above lands in the same whole second as the ssh itself, which
	// is as good as no prompt at all to timestamps of that resolution (see
	// observeRemote), so it is the prompt after this command that says the
	// far side is reporting - and it must be a command long enough to put
	// that prompt in a later second than its own start, which is why this
	// is a sleep and not a `true`.
	h.in("send-keys", "-t", pane, "sleep 1", "Enter")
	h.waitZshRow("╶✓ ssh localhost", "32")

	// A command on the far side. Nothing local runs, and the local pane's
	// foreground process is still ssh; the only thing that moves is the
	// OSC 133 state the remote shell writes down the connection.
	h.in("send-keys", "-t", pane, "sleep 3", "Enter")
	h.waitZshRow(running("╶◼ ssh localhost", "sleep 3"), "")

	// It exits zero on the far side, with the client in another window,
	// so the remote exit status reaches the row too.
	h.waitFor(func() bool { return h.zshRow("╶✓ ssh localhost", "32") },
		10*time.Second, msgf("a checkmark after the remote sleep"))
}
