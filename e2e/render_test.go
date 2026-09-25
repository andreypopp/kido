package e2e

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"kido/internal/testutil"
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

	// A pane split-window just created briefly reports its current command
	// as the forked server binary before the shell exec's, so wait for the
	// rows to settle on the wanted text rather than asserting once as soon
	// as the count is reached.
	want := []string{"zeta", "╶  " + shell, "alpha",
		"┌  " + shell, "├  " + shell, "└  " + shell}
	var rows []string
	h.waitFor(func() bool {
		rows = h.rows()
		if len(rows) != len(want) {
			return false
		}
		for i, w := range want {
			if strings.TrimSpace(rows[i]) != w {
				return false
			}
		}
		return true
	}, settle, func() string {
		return fmt.Sprintf("rows = %q, want %q", rows, want)
	})

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
	h.waitRow("╶  cat")

	h.waitSelected(shell)
	h.in("switch-client", "-c", h.client, "-t", "beta:1")
	h.waitSession("beta")

	h.waitSelected("cat")
	h.waitFor(func() bool {
		lines := h.capture()
		return selectedIndexOf(lines) == rowIndexOf(lines, "╶  cat")
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
// integration (shell/zsh/integration.zsh, sourced from a .zshrc the way a
// primed pane sources it) and expects the row to carry the same
// indicators an agent pane has: an empty two-column field at the prompt,
// a green ◼ while a command runs, a green ✓ once a command has exited
// zero, and a red ◼ once a command has exited nonzero, either until the
// pane is visited.
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
	// never reads their rc files.
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
	// label at the column every other row starts at. The shell's very
	// first prompt fires an OSC 133 "D" carrying whatever exit status the
	// rc left behind, with no "C" before it: shellOutcome's start-time
	// guard is what keeps that from marking a pane nothing has run in, so
	// this row is blank without the test ever visiting the pane.
	h.waitShellRow("╶  zsh", "")

	h.in("send-keys", "-t", pane, "sleep 5", "Enter")
	h.waitPaneCommand(pane, "sleep")
	// A patched tmux reports the command line the shell marked with its
	// 133;C, and the row shows that in place of #{pane_current_command}
	// - "sleep 5", not "sleep" - the same replacement ssh_remote_test.go
	// pins for a remote command. An unpatched tmux expands the format to
	// empty, which is also what a pane that never reported one looks
	// like, so the row stays what it always was.
	// Read once rather than poll: zsh's preexec fires the 133;C before the
	// command itself runs, so waitPaneCommand above has already ordered this
	// after it. Polling would wait out the whole settle on a tmux that never
	// fills the field, and the sleep being measured would end inside that wait.
	sleepRow := "╶◼ sleep"
	if h.in("display-message", "-p", "-t", pane, "#{pane_command_line}") != "" {
		sleepRow = "╶◼ sleep 5"
	}
	h.waitShellRow(sleepRow, "")

	// The sleep exits zero, and the client never left home, so it settles
	// on the checkmark, not blank - this is just a sync point before the
	// next command.
	h.waitFor(func() bool { return h.shellRow("╶✓ zsh", "32") },
		10*time.Second, msgf("the row a checkmark after the sleep"))

	// A command that fails leaves the row red until the pane is visited,
	// overriding the checkmark straight away.
	h.in("send-keys", "-t", pane, "false", "Enter")
	h.waitShellRow("╶◼ zsh", "31")

	// Visiting the pane clears it: the failure is older than the visit.
	h.in("select-window", "-t", pane)
	h.in("select-pane", "-t", pane)
	h.waitSelected("zsh")
	h.in("select-window", "-t", home)
	h.in("select-pane", "-t", home)
	h.waitShellRow("╶  zsh", "")

	// CommandEndTime has one-second resolution and the seen comparison is
	// strict (see shellOutcome), so let the visit above age past its
	// second before the next command, or the two can land in the same
	// tick and the outcome goes uncounted.
	time.Sleep(1200 * time.Millisecond)

	// A command that succeeds while the client is looking at a different
	// pane leaves the row a green checkmark, same as a done agent pane.
	h.in("send-keys", "-t", pane, "true", "Enter")
	h.waitShellRow("╶✓ zsh", "32")

	// Visiting the pane clears it: the success is older than the visit.
	h.in("select-window", "-t", pane)
	h.in("select-pane", "-t", pane)
	h.waitSelected("zsh")
	h.in("select-window", "-t", home)
	h.in("select-pane", "-t", home)
	h.waitShellRow("╶  zsh", "")
}

// shellRow reports whether the sidebar holds exactly the row want, with (or
// without) the given colour on it. want "" asks only that the row is not
// red - the running indicator is green too, so callers checking the running
// or idle row pass "" and callers checking a settled outcome pass "31" or
// "32". Text and colour are read from one capture, so a row cannot be
// matched in one frame and coloured in another.
func (h *harness) shellRow(want string, color string) bool {
	h.t.Helper()
	for _, line := range h.capture() {
		if sideText(line) == want {
			side := sideOf(line)
			if color == "" {
				return !hasSGR(side, "31")
			}
			return hasSGR(side, color)
		}
	}
	return false
}

func (h *harness) waitShellRow(want string, color string) {
	h.t.Helper()
	h.waitFor(func() bool { return h.shellRow(want, color) }, settle, func() string {
		return fmt.Sprintf("row %q (color=%q); rows are %q", want, color, h.rows())
	})
}

// TestBashShellStatusRow is TestShellStatusRow's twin for bash: a plain
// bash pane with shell/bash/integration.bash sourced the way a primed
// pane sources it carries the same indicators, off the
// same OSC 133 markers, through the same states.
func TestBashShellStatusRow(t *testing.T) {
	t.Parallel()
	bash := testutil.ModernBash(t)
	h := start(t, "alpha")

	home := ""
	for _, p := range h.panes() {
		if p.Session == "alpha" && p.Active {
			home = p.ID
		}
	}
	if home == "" {
		t.Fatal("no active pane in alpha")
	}

	script, err := filepath.Abs(filepath.Join("..", "shell", "bash", "integration.bash"))
	if err != nil {
		t.Fatal(err)
	}
	rc := filepath.Join(h.dir, "bashrc")
	if err := os.WriteFile(rc, []byte(fmt.Sprintf("source %q\n", script)), 0o644); err != nil {
		t.Fatal(err)
	}
	// --rcfile rather than a home of its own: bash has no ZDOTDIR, and
	// the test must never read the developer's rc files. -i because the
	// pane is a tty but the shell is exec'd with argv, which is what
	// makes the window's first process bash itself.
	pane := h.newWindow("alpha", "", bash, "--rcfile", rc, "-i")
	h.waitPaneCommand(pane, "bash")
	// The shell has to have reached its first prompt before anything is
	// typed at it, or the line is read by a terminal nobody is listening
	// at yet; that prompt is also the marker the row below is drawn from.
	h.waitPanePrompt(pane)
	// An idle integrated shell shows nothing, in a field that keeps the
	// label at the column every other row starts at. bash's first prompt
	// fires no "D" at all - nothing has run - so this row is blank
	// without the test ever visiting the pane.
	h.waitShellRow("╶  bash", "")

	h.in("send-keys", "-t", pane, "sleep 5", "Enter")
	h.waitPaneCommand(pane, "sleep")
	// A patched tmux reports the command line the shell marked with its
	// 133;C, and the row shows that in place of #{pane_current_command}.
	// Read once rather than poll, for the reason TestShellStatusRow gives.
	sleepRow := "╶◼ sleep"
	if h.in("display-message", "-p", "-t", pane, "#{pane_command_line}") != "" {
		sleepRow = "╶◼ sleep 5"
	}
	h.waitShellRow(sleepRow, "")

	// The sleep exits zero, and the client never left home, so it settles
	// on the checkmark.
	h.waitFor(func() bool { return h.shellRow("╶✓ bash", "32") },
		10*time.Second, msgf("the row a checkmark after the sleep"))

	// A command that fails leaves the row red until the pane is visited.
	h.in("send-keys", "-t", pane, "false", "Enter")
	h.waitShellRow("╶◼ bash", "31")

	// Visiting the pane clears it: the failure is older than the visit.
	// Both rows are labelled bash, the harness's own pane being a bash
	// too, so the wait is on the row losing its red rather than on
	// h.waitSelected - which the other pane's row satisfies at once, and
	// the test would switch away again before kido had seen the visit at
	// all.
	h.in("select-window", "-t", pane)
	h.in("select-pane", "-t", pane)
	h.waitFor(func() bool { return h.selectedRow() == "╶  bash" }, settle,
		msgf("the visited bash row clear of its red"))
	h.in("select-window", "-t", home)
	h.in("select-pane", "-t", home)
	h.waitShellRow("╶  bash", "")
}
