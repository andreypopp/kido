package e2e

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/x/ansi"
)

// Checks the list's shape: sessions oldest first, client's session bold,
// window grouping glyphs, process names.
func TestRenderGrouping(t *testing.T) {
	t.Parallel()
	h := start(t, "zeta")

	// session_created has one-second resolution and ties break by name, so
	// let the first session age before creating the second.
	time.Sleep(1200 * time.Millisecond)
	h.newSession("alpha")
	h.in("split-window", "-d", "-t", "alpha:")
	h.in("split-window", "-d", "-t", "alpha:")

	// A just-split pane briefly reports the forked server binary as its
	// command before the shell exec's, so wait for rows to settle.
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

	if !h.isBold("zeta") { // created first, client attached to it
		t.Error("current session zeta is not bold")
	}
	if h.isBold("alpha") {
		t.Error("alpha is bold but is not the client's session")
	}
}

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

func TestSSHRow(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	// ssh blocks on the proxy command, so no network is needed.
	pane := h.newWindow("alpha", "")
	// ssh is a child of the pane's shell; kido keys the destination by ssh's ppid.
	h.in("send-keys", "-t", pane,
		"ssh -F /dev/null -o ProxyCommand="+h.sshProxy()+" deploy@example.test", "Enter")
	h.waitPaneCommand(pane, "ssh")
	h.waitRow("ssh deploy@example.test")
}

// A pane whose root process is ssh itself (e.g. `tmux new-window 'ssh
// host'`), not a shell that then ran ssh: kido must key the destination
// by ssh's own pid too.
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

// A plain zsh pane through kido's OSC 133 integration must carry the
// same indicators an agent pane has: empty at the prompt, green ◼ while
// running, green ✓ on exit zero, red ◼ on exit nonzero, either until
// the pane is visited.
func TestShellStatusRow(t *testing.T) {
	t.Parallel()
	zsh, err := exec.LookPath("zsh")
	if err != nil {
		t.Skip("no zsh in PATH")
	}
	h := start(t, "alpha")

	// The pane to come back to: a visited (selected) row has its colours
	// stripped, so the colour checks below only mean something elsewhere.
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
	zdot := filepath.Join(h.dir, "zdotdir") // own ZDOTDIR, never the developer's rc files
	if err := os.MkdirAll(zdot, 0o755); err != nil {
		t.Fatal(err)
	}
	rc := fmt.Sprintf("source %q\n", script)
	if err := os.WriteFile(filepath.Join(zdot, ".zshrc"), []byte(rc), 0o644); err != nil {
		t.Fatal(err)
	}
	h.in("set-environment", "-g", "ZDOTDIR", zdot)
	h.in("set-option", "-g", "default-shell", zsh)

	pane := h.newWindow("alpha", "") // no argv, so the pane runs the default shell
	h.waitPaneCommand(pane, "zsh")
	// The first prompt fires an OSC 133 "D" carrying the rc's exit status
	// with no "C" before it; Ui.shell_outcome's start-time guard is what keeps
	// that from marking the pane as having run something.
	h.waitShellRow("╶  zsh", "")

	h.in("send-keys", "-t", pane, "sleep 5", "Enter")
	h.waitPaneCommand(pane, "sleep")
	// The row shows the 133;C command line in place of #{pane_current_command}
	// ("sleep 5", not "sleep"; ssh_remote_test.go pins the remote case).
	// Read once, not polled: zsh's preexec fires 133;C before the command
	// runs, so waitPaneCommand above already ordered this after it.
	h.waitShellRow("╶◼ sleep 5", "")

	h.waitFor(func() bool { return h.shellRow("╶✓ zsh", "32") },
		10*time.Second, msgf("the row a checkmark after the sleep"))

	h.in("send-keys", "-t", pane, "false", "Enter") // fails, row goes red until visited
	h.waitShellRow("╶◼ zsh", "31")

	h.in("select-window", "-t", pane)
	h.in("select-pane", "-t", pane)
	h.waitSelected("zsh")
	h.in("select-window", "-t", home)
	h.in("select-pane", "-t", home)
	h.waitShellRow("╶  zsh", "")

	// pane_command_end_time has one-second resolution and Ui.shell_outcome's seen
	// comparison is strict, so age past the visit's second or the two land
	// in the same tick and the outcome goes uncounted.
	time.Sleep(1200 * time.Millisecond)

	h.in("send-keys", "-t", pane, "true", "Enter") // succeeds while client is elsewhere
	h.waitShellRow("╶✓ zsh", "32")

	// Visiting the pane clears it: the success is older than the visit.
	h.in("select-window", "-t", pane)
	h.in("select-pane", "-t", pane)
	h.waitSelected("zsh")
	h.in("select-window", "-t", home)
	h.in("select-pane", "-t", home)
	h.waitShellRow("╶  zsh", "")
}

// shellRow's color "" asks only that the row is not red (the running
// indicator is green too, so running/idle callers pass ""; a settled
// outcome passes "31" or "32"). Text and colour come from one capture,
// so a row cannot be matched in one frame and coloured in another.
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

// TestShellStatusRow's twin for bash: a plain bash pane with
// integration.bash sourced carries the same indicators, off the same
// OSC 133 markers, through the same states.
func TestBashShellStatusRow(t *testing.T) {
	t.Parallel()
	bash := modernBash(t)
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
	// --rcfile: bash has no ZDOTDIR. -i: the shell is exec'd with argv, so
	// the window's first process is bash itself, and needs -i for a tty.
	pane := h.newWindow("alpha", "", bash, "--rcfile", rc, "-i")
	h.waitPaneCommand(pane, "bash")
	h.waitPanePrompt(pane) // typing before the first prompt is read by nobody listening yet
	// bash's first prompt fires no "D" at all - nothing has run.
	h.waitShellRow("╶  bash", "")

	h.in("send-keys", "-t", pane, "sleep 5", "Enter")
	h.waitPaneCommand(pane, "sleep")
	// Read once rather than poll, for the reason TestShellStatusRow gives.
	h.waitShellRow("╶◼ sleep 5", "")

	h.waitFor(func() bool { return h.shellRow("╶✓ bash", "32") },
		10*time.Second, msgf("the row a checkmark after the sleep"))

	h.in("send-keys", "-t", pane, "false", "Enter") // fails, row goes red until visited
	h.waitShellRow("╶◼ bash", "31")

	// Both rows are labelled bash (the harness's own pane too), so wait on
	// the row losing its red rather than on h.waitSelected, which the
	// other pane's row satisfies at once.
	h.in("select-window", "-t", pane)
	h.in("select-pane", "-t", pane)
	h.waitFor(func() bool { return h.selectedRow() == "╶  bash" }, settle,
		msgf("the visited bash row clear of its red"))
	h.in("select-window", "-t", home)
	h.in("select-pane", "-t", home)
	h.waitShellRow("╶  bash", "")
}

// The selected row inverts the label's title alone: not the tree glyph,
// the indicator field, the activity after the title, or the padding out
// to the column's width.
func TestSelectedRowInvertsTitleOnly(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.in("display-message", "-p", "-t", "alpha:", "#{pane_id}")
	h.agentStatus("sel-1", pane, "pi", "running", "--title", "deploy", "--activity", "testing")
	h.waitSelected("deploy  testing")

	var line string
	for _, l := range h.capture() {
		if hasSGR(sideOf(l), "7") {
			line = sideOf(l)
		}
	}
	on := reverseRE.FindStringIndex(line)
	if on == nil {
		t.Fatalf("no selected row in %q", line)
	}
	inverted, rest, _ := strings.Cut(line[on[1]:], "\x1b[")
	if inverted != "deploy" {
		t.Errorf("inverted %q, want the title alone; row %q", inverted, line)
	}
	if before := ansi.Strip(line[:on[0]]); !strings.HasPrefix(before, "╶") {
		t.Errorf("before the title %q, want the tree glyph and indicator uninverted", before)
	}
	if hasSGR(rest, "7") {
		t.Errorf("more than the title inverted: %q", line)
	}
}
