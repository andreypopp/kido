package e2e

import (
	"fmt"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/x/ansi"
)

// The launcher is `kido` with no arguments: it starts or attaches to
// kido's own tmux server, on the socket named "kido". These tests run it
// the way a user does - typed at a terminal with no tmux around it, which
// here is a pty in the outer server - and read back the server it
// produced.
//
// Every one of them gets a TMUX_TMPDIR of its own, so the socket called
// "kido" is this test's and never the developer's own running one. That
// is the only reason it is safe to name a fixed socket at all, and the
// same reason the cleanup below may kill a server by that name.

// kidoRun is one launcher test's world: a temporary HOME and
// XDG_CONFIG_HOME for the configuration layering, a TMUX_TMPDIR holding
// the kido socket, and an outer tmux server providing ptys to type into.
type kidoRun struct {
	t      *testing.T
	dir    string
	home   string
	config string
	tmpdir string
	state  string
	outer  string
	shell  string
}

// newKidoRun builds that world but starts no kido: a test that writes a
// kido.conf or a .tmux.conf has to do it before the server reads one.
func newKidoRun(t *testing.T) *kidoRun {
	t.Helper()
	requireTmux(t)

	r := &kidoRun{t: t, dir: t.TempDir()}
	r.home = filepath.Join(r.dir, "home")
	r.config = filepath.Join(r.dir, "config")
	r.state = filepath.Join(r.dir, "state")
	// The socket directory is tmux's own: it insists on 0700 and on
	// owning it, and it must be short enough for a unix socket path.
	tmpdir, err := os.MkdirTemp("", "kido-sock")
	if err != nil {
		t.Fatal(err)
	}
	r.tmpdir = tmpdir
	for _, d := range []string{r.home, r.config, r.state} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	r.shell = primableShell(t, r.home)
	r.outer = fmt.Sprintf("kido-l-%s-%d-%d", sanitize.ReplaceAllString(t.Name(), "-"),
		os.Getpid(), rand.Int32N(1<<20))

	t.Cleanup(func() {
		// The kido server first: killing the outer one only takes away the
		// terminals its clients sit in.
		r.kido("kill-server")
		killServer(r.outer)
		os.RemoveAll(r.tmpdir)
	})

	r.mustOuter("-f", "/dev/null", "new-session", "-d", "-s", "host",
		"-x", strconv.Itoa(outerCols), "-y", strconv.Itoa(outerRows))
	r.mustOuter("set-option", "-g", "default-terminal", "screen-256color")
	r.mustOuter("set-option", "-g", "remain-on-exit", "on")
	return r
}

// primableShell is a login shell `kido shell` can actually prime, with
// whatever dotfiles that shell needs to be primed at all: zsh is left
// alone unless it has some (zsh-newuser-install), and Apple's bash 3.2 is
// too old for PS0 whatever its dotfiles say. A machine with neither skips
// rather than passing on a pane that reports nothing.
//
// Nothing kido knows about goes into the file: that a pane reports with
// no kido line in any rc file is the claim the shell test makes.
func primableShell(t *testing.T, home string) string {
	t.Helper()
	if zsh, err := exec.LookPath("zsh"); err == nil {
		rc := filepath.Join(home, ".zshrc")
		if err := os.WriteFile(rc, []byte("PS1='kido$ '\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		return zsh
	}
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("no zsh and no bash to prime")
	}
	out, err := exec.Command(bash, "-c", `echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"`).Output()
	if err != nil || strings.Compare(strings.TrimSpace(string(out)), "4.4") < 0 {
		t.Skipf("no zsh, and %s is %q: too old for PS0", bash, strings.TrimSpace(string(out)))
	}
	return bash
}

// env is what a launcher test's kido runs with: its own home,
// configuration, state and socket directory, and a shell it can prime.
func (r *kidoRun) env() []string {
	return []string{
		"HOME=" + r.home,
		"XDG_CONFIG_HOME=" + r.config,
		"TMUX_TMPDIR=" + r.tmpdir,
		"KIDO_STATE_DIR=" + r.state,
		"SHELL=" + r.shell,
	}
}

// envAssign is env() as one shell prefix, for a command typed into a pane
// or handed to the outer server's new-window.
func (r *kidoRun) envAssign() string {
	var parts []string
	for _, kv := range r.env() {
		name, value, _ := strings.Cut(kv, "=")
		parts = append(parts, fmt.Sprintf("%s=%q", name, value))
	}
	return strings.Join(parts, " ")
}

func (r *kidoRun) mustOuter(args ...string) string {
	r.t.Helper()
	full := append([]string{"-L", r.outer}, args...)
	cmd := exec.Command(tmuxBin, full...)
	cmd.Env = cleanEnv("TMUX=")
	out, err := cmd.CombinedOutput()
	if err != nil {
		r.t.Fatalf("tmux -L %s %s: %v: %s", r.outer, strings.Join(args, " "), err, out)
	}
	return strings.TrimRight(string(out), "\n")
}

// kido runs a tmux command against the server on the kido socket. It
// returns the error rather than failing, because "is there a server yet"
// is a question these tests poll.
func (r *kidoRun) kido(args ...string) (string, error) {
	r.t.Helper()
	full := append([]string{"-L", "kido"}, args...)
	cmd := exec.Command(tmuxBin, full...)
	cmd.Env = cleanEnv("TMUX=", "TMUX_TMPDIR="+r.tmpdir)
	out, err := cmd.Output()
	return strings.TrimRight(string(out), "\n"), err
}

func (r *kidoRun) mustKido(args ...string) string {
	r.t.Helper()
	out, err := r.kido(args...)
	if err != nil {
		r.t.Fatalf("tmux -L kido %s: %v", strings.Join(args, " "), err)
	}
	return out
}

// launch types a bare `kido` into a new pty of the outer server, named
// window, which is exactly how a user starts one: no arguments, and no
// TMUX around it.
func (r *kidoRun) launch(window string) {
	r.t.Helper()
	r.mustOuter("new-window", "-d", "-t", "host", "-n", window,
		fmt.Sprintf("unset TMUX; exec env %s %q", r.envAssign(), kidoBin))
}

// waitUp waits until a server answers on the kido socket.
func (r *kidoRun) waitUp() {
	r.t.Helper()
	r.waitFor(func() bool { _, err := r.kido("list-sessions"); return err == nil },
		"a server to answer on the kido socket")
}

// waitFor polls cond, reporting what the outer screens showed at the
// deadline: a launcher that refused says so there and nowhere else.
func (r *kidoRun) waitFor(cond func() bool, what string) {
	r.t.Helper()
	deadline := time.Now().Add(settle)
	for {
		if cond() {
			return
		}
		if time.Now().After(deadline) {
			r.t.Fatalf("timed out waiting for %s\nouter windows:\n%s\n%s", what,
				r.mustOuter("list-windows", "-t", "host", "-F", "#{window_name}"),
				strings.Join(r.captureAll(), "\n"))
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// capture is one outer window's screen as plain text lines.
func (r *kidoRun) capture(window string) []string {
	r.t.Helper()
	out := r.mustOuter("capture-pane", "-p", "-t", "host:"+window)
	return strings.Split(ansi.Strip(out), "\n")
}

// captureAll is every outer window's screen, for a failure message.
func (r *kidoRun) captureAll() []string {
	r.t.Helper()
	var out []string
	for _, w := range strings.Split(r.mustOuter("list-windows", "-t", "host", "-F", "#{window_name}"), "\n") {
		if w == "" || w == "host" {
			continue
		}
		out = append(out, "--- "+w+" ---")
		out = append(out, r.capture(w)...)
	}
	return out
}

// sidebarUp reports whether the kido client in window has drawn the side
// column: its separator sits at column sideWidth, the width kido's own
// defaults set.
func (r *kidoRun) sidebarUp(window string) bool {
	r.t.Helper()
	for _, line := range r.capture(window) {
		if runes := []rune(line); len(runes) >= sideWidth && runes[sideWidth-1] == '│' {
			return true
		}
	}
	return false
}

// realClients is the number of clients attached to the kido server that
// are not one of kido's own control connections - the sidebar dials one
// per real client, so counting them all would count the sidebar twice.
func (r *kidoRun) realClients() int {
	r.t.Helper()
	out, err := r.kido("list-clients", "-F", "#{client_control_mode}")
	if err != nil {
		return 0
	}
	n := 0
	for _, line := range strings.Split(out, "\n") {
		if strings.TrimSpace(line) == "0" {
			n++
		}
	}
	return n
}

// firstPane is the pane of the session the launcher created.
func (r *kidoRun) firstPane() string {
	r.t.Helper()
	return strings.Split(r.mustKido("list-panes", "-a", "-F", "#{pane_id}"), "\n")[0]
}

// TestKidoStartsAServerWithASidebar is the launcher's first claim: a bare
// `kido` at a plain terminal leaves a server on the kido socket, with the
// side column drawn and running this kido rather than whatever else is
// called kido on the machine.
func TestKidoStartsAServerWithASidebar(t *testing.T) {
	t.Parallel()
	r := newKidoRun(t)
	r.launch("first")
	r.waitUp()

	r.waitFor(func() bool { return r.sidebarUp("first") }, "the side column to be drawn")
	if got := r.mustKido("show-options", "-gv", "side-status-command"); !strings.Contains(got, kidoBin) {
		t.Errorf("side-status-command = %q, want the kido under test (%s)", got, kidoBin)
	}
	if got := r.mustKido("show-options", "-gv", "default-command"); !strings.Contains(got, "shell") {
		t.Errorf("default-command = %q, want `kido shell`", got)
	}
}

// TestASecondKidoAttaches pins the other half of the launcher: the second
// one starts nothing. What says so is the session count - one server, one
// session, two clients - rather than the second client merely existing,
// which a second server on a second socket would also give.
func TestASecondKidoAttaches(t *testing.T) {
	t.Parallel()
	r := newKidoRun(t)
	r.launch("first")
	r.waitUp()
	r.waitFor(func() bool { return r.realClients() == 1 }, "the first client to attach")

	r.launch("second")
	r.waitFor(func() bool { return r.realClients() == 2 }, "the second kido to attach")
	if got := r.mustKido("list-sessions", "-F", "#{session_name}"); strings.Contains(got, "\n") {
		t.Errorf("sessions = %q, want the one the first kido made", got)
	}
}

// TestKidoInsideAKidoPaneRefuses is the refusal, and the assertion with
// teeth is the last one: the server it was typed into gained no client.
// A refusal that printed its message and attached anyway satisfies
// everything else here, and the second client is the bug itself - a
// second prefix and a second status line over the one already there.
func TestKidoInsideAKidoPaneRefuses(t *testing.T) {
	t.Parallel()
	r := newKidoRun(t)
	r.launch("first")
	r.waitUp()
	r.waitFor(func() bool { return r.realClients() == 1 }, "the first client to attach")

	out := filepath.Join(r.dir, "refusal")
	pane := r.firstPane()
	r.mustKido("send-keys", "-t", pane,
		fmt.Sprintf("%q 2>%q; echo rc=$? >>%q", kidoBin, out, out), "Enter")

	var body string
	r.waitFor(func() bool {
		b, err := os.ReadFile(out)
		body = string(b)
		return err == nil && strings.Contains(body, "rc=")
	}, "the refusal and its exit code")
	if !strings.Contains(body, "plain terminal") {
		t.Errorf("kido said %q, want it to say where to run kido from", body)
	}
	if strings.Contains(body, "rc=0") {
		t.Errorf("kido exited 0 after refusing: %q", body)
	}

	// Over a span, not at an instant: "no client yet" and "no client
	// ever" look the same at any one reading.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if n := r.realClients(); n != 1 {
			t.Fatalf("the kido server has %d real clients, want the one that was there before the refusal", n)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// TestFirstPaneShellIsPrimed is what `kido shell` is for: the pane the
// launcher opened reports a prompt, and the command line of what runs in
// it, with no kido line in any file under the user's home. The rc file
// the shell does have is the one that shell needs to be started at all
// (primableShell), and it is checked for kido's name so that the claim
// cannot be quietly satisfied by a stray integration block.
func TestFirstPaneShellIsPrimed(t *testing.T) {
	t.Parallel()
	r := newKidoRun(t)
	r.launch("first")
	r.waitUp()
	pane := r.firstPane()

	r.waitFor(func() bool {
		return reportedPrompt(r.mustKido("display-message", "-p", "-t", pane, "#{pane_last_prompt_time}"))
	}, "the pane's shell to report its first prompt")
	assertNoKidoInHome(t, r.home)

	// #{pane_command_line} is newer than the rest of the OSC 133 support
	// and not in every build of the fork. A tmux without it expands the
	// name to the empty string, which is also what a shell reporting no
	// command line looks like - so, as in TestSSHRowShowsRemoteCommandLine,
	// the probe is the field itself and the test skips rather than
	// reporting a plain tmux as a broken kido.
	r.mustKido("send-keys", "-t", pane, "sleep 2", "Enter")
	deadline := time.Now().Add(settle)
	for time.Now().Before(deadline) {
		if line := r.mustKido("display-message", "-p", "-t", pane, "#{pane_command_line}"); line != "" {
			if !strings.Contains(line, "sleep 2") {
				t.Errorf("#{pane_command_line} = %q, want the command the pane is running", line)
			}
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Skip("tmux does not report #{pane_command_line}")
}

// assertNoKidoInHome checks the test's home has no shell integration in
// it: the priming must leave the user's dotfiles alone, and a pane that
// reports because something wrote a block into one proves nothing.
func assertNoKidoInHome(t *testing.T, home string) {
	t.Helper()
	entries, err := os.ReadDir(home)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		body, err := os.ReadFile(filepath.Join(home, e.Name()))
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(body), "kido") && !strings.Contains(string(body), "PS1=") {
			t.Errorf("%s mentions kido; the pane may be reporting from a dotfile rather than from priming:\n%s",
				e.Name(), body)
		}
	}
}

// TestKidoConfIsHonoured pins the middle layer: the user's own file is
// read, and an option it sets is the one the server ends up with.
func TestKidoConfIsHonoured(t *testing.T) {
	t.Parallel()
	r := newKidoRun(t)
	conf := filepath.Join(r.config, "kido")
	if err := os.MkdirAll(conf, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(conf, "kido.conf"),
		[]byte("set -g @kido-e2e from-kido-conf\nset -g side-status-width 33\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	r.launch("first")
	r.waitUp()
	if got := r.mustKido("show-options", "-gv", "@kido-e2e"); got != "from-kido-conf" {
		t.Errorf("@kido-e2e = %q, want the value kido.conf set", got)
	}
	// An option kido's own defaults already set, to show which layer wins
	// where they disagree.
	if got := r.mustKido("show-options", "-gv", "side-status-width"); got != "33" {
		t.Errorf("side-status-width = %q, want kido.conf's 33 over kido's default", got)
	}
}

// TestKidoConfDefaultCommandIsCaptured pins the one thing the launcher
// takes away and gives back: kido owns default-command, so a user who set
// their own in kido.conf would lose it, and it is captured into
// @kido-user-command before the override for `kido shell` to run in place
// of a bare shell.
//
// The assertion with teeth is the last one - the pane is really running
// their command - because the option alone only says the capture
// happened, not that anything reads it.
func TestKidoConfDefaultCommandIsCaptured(t *testing.T) {
	t.Parallel()
	r := newKidoRun(t)
	conf := filepath.Join(r.config, "kido")
	if err := os.MkdirAll(conf, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(conf, "kido.conf"),
		[]byte(`set -g default-command "sleep 300"`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	r.launch("first")
	r.waitUp()
	if got := r.mustKido("show-options", "-gv", "@kido-user-command"); got != "sleep 300" {
		t.Errorf("@kido-user-command = %q, want the default-command kido.conf set", got)
	}
	pane := r.firstPane()
	r.waitFor(func() bool {
		return r.mustKido("display-message", "-p", "-t", pane, "#{pane_current_command}") == "sleep"
	}, "the pane to be running the user's own default-command")
}

// TestKidoConfDefaultCommandNamingAShellIsPrimed is the bug fixed
// alongside TestKidoConfDefaultCommandIsCaptured: a user who wrote
// `set-option -g default-command "zsh"` - to skip the login shell, or
// for a wrapper like reattach-to-user-namespace - was handed an
// unprimed, non-login zsh with none of kido's integration, silently, in
// every pane. Pre-fix this failed with:
//
//	the pane's shell to report its first prompt: condition never became true
//
// because the parked command ran as `zsh -l -c zsh`: the outer login
// zsh is primed but the inner one is bare, non-interactive, and OSC 133
// never fires. TestKidoConfDefaultCommandIsCaptured pins the case this
// must not change: a real command still runs as the command.
func TestKidoConfDefaultCommandNamingAShellIsPrimed(t *testing.T) {
	t.Parallel()
	if _, err := exec.LookPath("zsh"); err != nil {
		t.Skip("no zsh in PATH")
	}
	r := newKidoRun(t)
	conf := filepath.Join(r.config, "kido")
	if err := os.MkdirAll(conf, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(conf, "kido.conf"),
		[]byte(`set -g default-command "zsh"`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	r.launch("first")
	r.waitUp()
	if got := r.mustKido("show-options", "-gv", "@kido-user-command"); got != "zsh" {
		t.Errorf("@kido-user-command = %q, want the default-command kido.conf set", got)
	}
	pane := r.firstPane()
	r.waitFor(func() bool {
		return reportedPrompt(r.mustKido("display-message", "-p", "-t", pane, "#{pane_last_prompt_time}"))
	}, "the pane's shell to report its first prompt")

	shims := filepath.Join(shareDir, "bin")
	if got := r.shellIn(pane, "command -v tmux"); !sameFile(got, filepath.Join(shims, "tmux")) {
		t.Errorf("command -v tmux = %q in the pane, want the shim in %s", got, shims)
	}
}

// TestTmuxConfIsIgnored is the decision that a kido server reads no
// ~/.tmux.conf: a configuration written for stock tmux fights the side
// column, and a user who wants theirs writes one source-file line in
// kido.conf. Its positive control is the test above - the same option
// name, set from the file kido does read.
func TestTmuxConfIsIgnored(t *testing.T) {
	t.Parallel()
	r := newKidoRun(t)
	if err := os.WriteFile(filepath.Join(r.home, ".tmux.conf"),
		[]byte("set -g @kido-e2e from-tmux-conf\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	r.launch("first")
	r.waitUp()
	r.waitFor(func() bool { return r.sidebarUp("first") }, "the side column to be drawn")
	if got := r.mustKido("show-options", "-gqv", "@kido-e2e"); got != "" {
		t.Errorf("@kido-e2e = %q: the user's ~/.tmux.conf was read", got)
	}
}
