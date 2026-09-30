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
// Unlike the patched tmux this is never required: a machine with no sshd
// is an ordinary place to run the suite, and KIDO_E2E_REQUIRED says
// nothing about it.
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

// A real ssh to localhost whose remote shell carries kido's OSC 133
// integration: the row must report the remote shell's commands (tmux
// parses the markers off the local pane's output stream however far away
// they were written), with the destination still the label.
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
	// One ZDOTDIR for both ends (same filesystem, same user): the local
	// shell needs the integration too, since the gate is a remote prompt
	// marked after the local shell marked ssh as started.
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
	h.waitShellRow("╶  zsh", "")

	// -tt forces a pty for a remote interactive shell - the pane kido used
	// to suppress wholesale. ZDOTDIR is spelled out since ssh forwards no
	// environment.
	h.in("send-keys", "-t", pane, fmt.Sprintf("ssh -tt %s localhost %q",
		strings.Join(sshOpts, " "), "ZDOTDIR="+zdot+" exec "+zsh+" -i"), "Enter")
	h.waitPaneCommand(pane, "ssh")
	// Whether a running row names the far side's command depends on the
	// tmux under test: one without the pane_command_line patch expands the
	// name to empty.
	withCmd := h.in("display-message", "-p", "-t", pane, "#{pane_command_line}") != ""
	running := func(row, cmd string) string {
		if withCmd {
			return row + ": " + cmd
		}
		return row
	}
	h.waitShellRow("╶  ssh localhost", "")

	// Over a loopback connection the prompt above lands in the same whole
	// second as the ssh itself, as good as no prompt at all to timestamps
	// of that resolution (Ui.observe_remote); this sleep, not `true`, puts the
	// next prompt in a later second so it is the one that says the far
	// side is reporting. Its exit status crossing the connection is also
	// the first thing a suppressed ssh pane could not show.
	h.in("send-keys", "-t", pane, "sleep 1", "Enter")
	h.waitShellRow("╶✓ ssh localhost", "32")

	// The local pane's foreground process is still ssh; only the remote
	// shell's OSC 133 state moves down the connection.
	h.in("send-keys", "-t", pane, "sleep 3", "Enter")
	h.waitShellRow(running("╶◼ ssh localhost", "sleep 3"), "")

	h.waitFor(func() bool { return h.shellRow("╶✓ ssh localhost", "32") },
		10*time.Second, msgf("a checkmark after the remote sleep"))
}
