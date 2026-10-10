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

// sshSettle is how long a remote round trip is given. It is not settle:
// every wait here is behind a real ssh handshake and a remote login
// shell's rc files, which on a loaded machine outlast kido's own 5s.
const sshSettle = 20 * time.Second

// integratedShellPane's shell carries kido's own integration. An ssh
// pane needs one: kido only believes a far side is reporting once it
// marks a prompt later than the local shell marked the ssh as started
// (Sidebar.observe_remote).
func integratedShellPane(t *testing.T, h *harness) string {
	t.Helper()
	zsh, err := exec.LookPath("zsh")
	if err != nil {
		t.Skip("no zsh in PATH")
	}
	script, err := filepath.Abs(filepath.Join("..", "share", "zsh", "integration.zsh"))
	if err != nil {
		t.Fatal(err)
	}
	zdot := filepath.Join(h.dir, "zdotdir")
	if err := os.MkdirAll(zdot, 0o755); err != nil {
		t.Fatal(err)
	}
	rc := fmt.Sprintf("source %q\nPS1='local%% '\n", script)
	if err := os.WriteFile(filepath.Join(zdot, ".zshrc"), []byte(rc), 0o644); err != nil {
		t.Fatal(err)
	}
	h.in("set-environment", "-g", "ZDOTDIR", zdot)
	h.in("set-option", "-g", "default-shell", zsh)

	pane := h.newWindow("alpha", "")
	h.waitPaneCommand(pane, "zsh")
	h.waitShellRow("╶ zsh", "")
	return pane
}

// `kido ssh` end to end: a real ssh, a real remote login shell, the
// sidebar reading what it reports. Plain `ssh` first, `kido ssh` second
// on the same destination from the same pane, since the row only means
// something if the connection says nothing without priming.
//
// A remote whose own dotfiles already source kido's integration reports
// either way - most often the developer's own localhost - and this test
// can prove nothing about priming there: it skips rather than passing on
// the far side's own rc files. The pristine-remote evidence lives where
// a pristine remote can be built - lib/test/test_prime.ml's "the bootstrap
// primes a pristine zsh".
func TestKidoSSHPrimesARemoteShell(t *testing.T) {
	t.Parallel()
	requireLocalSSH(t)
	h := start(t, "alpha")
	pane := integratedShellPane(t, h)
	opts := strings.Join(sshOpts, " ")

	// A remote command long enough for its prompt to land in a later
	// second than its own start: tmux's timestamps are whole seconds, so a
	// `true` would be indistinguishable from silence.
	remote := func(cmd string) { h.in("send-keys", "-t", pane, cmd, "Enter") }
	reports := func(d time.Duration) bool {
		deadline := time.Now().Add(d)
		for time.Now().Before(deadline) {
			if h.shellRow("╶✓ssh "+localSSHDestination(t), "32") {
				return true
			}
			time.Sleep(100 * time.Millisecond)
		}
		return false
	}

	h.in("send-keys", "-t", pane, kidoBin+" ssh -tt "+opts+" localhost 'exec \"$SHELL\" -i'", "Enter")
	h.waitPaneCommand(pane, "ssh")
	remote("sleep 1")
	if reports(sshSettle) {
		remote("exit")
		t.Skip("localhost's own dotfiles already report to kido, so priming cannot be shown to be the cause here")
	}
	// Negative control: this far side says nothing on its own.
	if h.shellRow("╶✓ssh "+localSSHDestination(t), "32") {
		t.Fatalf("the unprimed remote reported after all; rows are %q", h.rows())
	}
	h.waitShellRow("╶◼ssh "+localSSHDestination(t), "")
	remote("exit")
	h.waitPaneCommand(pane, "zsh")

	h.in("send-keys", "-t", pane, kidoBin+" ssh "+opts+" localhost", "Enter")
	h.waitPaneCommand(pane, "ssh")
	remote("sleep 1")
	if !reports(sshSettle) {
		t.Fatalf("the primed remote did not report; rows are %q\npane:\n%s",
			h.rows(), h.in("capture-pane", "-p", "-t", pane))
	}
}

// The plumbing `kido ssh` has to get right whoever the far side is: the
// arguments reach ssh in order, kido exec's into it, and the connection
// is an interactive login shell running what is typed at it - which it
// would not be without the -t kido adds, ssh allocating no tty for the
// bootstrap it now carries.
//
// Asserts nothing about priming; a remote reporting through its own
// dotfiles gives the same row. Catches a bootstrap that wedges, a
// quoting mistake reaching the remote shell as commands, or a fallback
// that never execs anything.
func TestKidoSSHOpensAnOrdinarySession(t *testing.T) {
	t.Parallel()
	requireLocalSSH(t)
	h := start(t, "alpha")
	pane := integratedShellPane(t, h)

	h.in("send-keys", "-t", pane, kidoBin+" ssh "+strings.Join(sshOpts, " ")+" localhost", "Enter")
	// kido exec's ssh, so the pane's foreground process is ssh itself.
	h.waitPaneCommand(pane, "ssh")
	// The destination is still the label, whatever the far side reports.
	h.waitRow("ssh " + localSSHDestination(t))

	h.in("send-keys", "-t", pane, "echo kido-remote-$((21*2))", "Enter")
	h.waitFor(func() bool {
		return strings.Contains(h.in("capture-pane", "-p", "-t", pane), "kido-remote-42")
	}, sshSettle, func() string {
		return "the remote shell to run a command\npane:\n" + h.in("capture-pane", "-p", "-t", pane)
	})
}
