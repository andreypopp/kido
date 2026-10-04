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
	// kidoSock is the full path of the socket called "kido" under tmpdir.
	kidoSock string
}

// newKidoRun builds that world but starts no kido: a test writing a
// kido.conf or .tmux.conf must do it before the server reads one.
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
	// Where the launcher's server will put its socket: this test's own
	// TMUX_TMPDIR decides it, and every tmux command below addresses that
	// path rather than the name "kido". The name would be resolved against
	// a list of directories that ends in /tmp, so the moment this
	// directory stops resolving - the cleanup below deletes it - the name
	// means the developer's own live server instead. That is not
	// hypothetical: it happened.
	r.kidoSock = socketPath(r.tmpdir, "kido")
	watchSockets(r.outer)
	watchSocketIn(r.tmpdir, "kido")

	t.Cleanup(func() {
		started := descendants(r.kidoSock)
		// The kido server first: killing the outer one only takes away the
		// terminals its clients sit in.
		r.kido("kill-server")
		killServer(r.outer)
		deadline := time.Now().Add(settle)
		for _, p := range started {
			if !processGone(p.pid, time.Until(deadline)) {
				t.Errorf("pid %s (%s), started under %s, outlived its server by %v", p.pid, p.command, r.kidoSock, settle)
			}
		}
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

func (r *kidoRun) env() []string {
	return []string{
		"HOME=" + r.home,
		"XDG_CONFIG_HOME=" + r.config,
		"TMUX_TMPDIR=" + r.tmpdir,
		"KIDO_STATE_DIR=" + r.state,
		"SHELL=" + r.shell,
		// Empty is unset: every launch here must still find the kido-tmux
		// beside kido.
		"KIDO_TMUX=",
	}
}

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
	full := append([]string{"-S", r.kidoSock}, args...)
	cmd := exec.Command(tmuxBin, full...)
	cmd.Env = cleanEnv("TMUX=", "TMUX_TMPDIR="+r.tmpdir)
	out, err := cmd.Output()
	return strings.TrimRight(string(out), "\n"), err
}

func (r *kidoRun) mustKido(args ...string) string {
	r.t.Helper()
	out, err := r.kido(args...)
	if err != nil {
		var stderr []byte
		if exit, ok := err.(*exec.ExitError); ok {
			stderr = exit.Stderr
		}
		r.t.Fatalf("tmux -S %s %s: %v: %s%s", r.kidoSock, strings.Join(args, " "), err, out, stderr)
	}
	return out
}

// launch types a bare `kido` into a new pty of the outer server, named
// window, which is exactly how a user starts one: no arguments, and no
// TMUX around it.
func (r *kidoRun) launch(window string) {
	r.t.Helper()
	args := ""
	if name := filepath.Base(r.kidoSock); name != "kido" {
		args = fmt.Sprintf(" --socket-name %q", name)
	}
	r.mustOuter("new-window", "-d", "-t", "host", "-n", window,
		fmt.Sprintf("unset TMUX; exec env %s %q%s", r.envAssign(), kidoBin, args))
}

// waitUp waits until the launcher's initial session exists.
func (r *kidoRun) waitUp() {
	r.t.Helper()
	r.waitFor(func() bool {
		out, err := r.kido("list-sessions", "-F", "#{session_name}")
		return err == nil && out != ""
	}, "the initial session on the kido socket")
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

func (r *kidoRun) capture(window string) []string {
	r.t.Helper()
	out := r.mustOuter("capture-pane", "-p", "-t", "host:"+window)
	return strings.Split(ansi.Strip(out), "\n")
}

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

func (r *kidoRun) firstPane() string {
	r.t.Helper()
	return strings.Split(r.mustKido("list-panes", "-a", "-F", "#{pane_id}"), "\n")[0]
}

// A bare `kido` at a plain terminal leaves a server on the kido socket,
// with the side column drawn and running this kido, not whatever else on
// the machine is called kido.
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

// A second `kido` attaches rather than starting anything: pinned by the
// session count (one server, one session, two clients), not merely by a
// second client existing, which a second server on a second socket would
// also give.
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

// The assertion with teeth is the last one: the server it was typed into
// gained no client. A refusal that printed its message and attached
// anyway would satisfy everything before it.
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

	// Over a span: "no client yet" and "no client ever" look the same at
	// any one reading.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if n := r.realClients(); n != 1 {
			t.Fatalf("the kido server has %d real clients, want the one that was there before the refusal", n)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// What `kido shell` is for: the launched pane reports a prompt and its
// running command line with no kido line in any dotfile - checked for
// kido's name so the claim cannot be satisfied by a stray block.
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
	t.Fatal("#{pane_command_line} never reported the running command")
}

// assertNoKidoInHome: priming must leave the user's dotfiles alone.
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

// The user's own kido.conf is read, and an option it sets is what the
// server ends up with.
func TestKidoConfIsHonoured(t *testing.T) {
	t.Parallel()
	r := newKidoRun(t)
	conf := filepath.Join(r.config, "kido")
	if err := os.MkdirAll(conf, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(conf, "kido.conf"),
		[]byte("set -g @kido-e2e from-kido-conf\nset -g side-status-width 33\n"+
			"set -g side-status-command false\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	r.launch("first")
	r.waitUp()
	if got := r.mustKido("show-options", "-gv", "@kido-e2e"); got != "from-kido-conf" {
		t.Errorf("@kido-e2e = %q, want the value kido.conf set", got)
	}
	if got := r.mustKido("show-options", "-gv", "side-status-width"); got != "33" { // kido's own default, shows which layer wins
		t.Errorf("side-status-width = %q, want kido.conf's 33 over kido's default", got)
	}
	// What kido owns is set after kido.conf is sourced.
	if got := r.mustKido("show-options", "-gv", "side-status-command"); !strings.Contains(got, kidoBin) {
		t.Errorf("side-status-command = %q, want the kido under test over kido.conf's", got)
	}
}

// kido owns default-command, so a user's own value in kido.conf is
// captured into @kido-user-command before the override, for `kido shell`
// to run in place of a bare shell. The last assertion is the one with
// teeth: the option alone says the capture happened, not that it is used.
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

// A shell named by default-command needs priming and OSC 133 integration.
// TestKidoConfDefaultCommandIsCaptured is the negative control: a real
// command must still run as the command.
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
		[]byte("run-shell 'sleep 0.5'\n"+`set -g default-command "zsh"`+"\n"), 0o644); err != nil {
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

// A kido server reads no ~/.tmux.conf: a config written for stock tmux
// fights the side column. Positive control is the test above, the same
// option name set from the file kido does read.
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

// With no XDG_CONFIG_HOME, kido.conf is read from ~/.config.
func TestKidoConfUnderDotConfig(t *testing.T) {
	t.Parallel()
	r := newKidoRun(t)
	r.config = ""
	conf := filepath.Join(r.home, ".config", "kido")
	if err := os.MkdirAll(conf, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(conf, "kido.conf"),
		[]byte("set -g @kido-e2e from-dot-config\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	r.launch("first")
	r.waitUp()
	if got := r.mustKido("show-options", "-gv", "@kido-e2e"); got != "from-dot-config" {
		t.Errorf("@kido-e2e = %q, want the value ~/.config/kido/kido.conf set", got)
	}
}

// A kido under a path with a space: sh parses side-status-command and
// default-command, and must see the path as one word. Started through a
// symlink, with no tmux on PATH to fall back on, it runs the kido-tmux
// beside the file the link names.
func TestKidoAtAPathWithASpace(t *testing.T) {
	t.Parallel()
	r := newKidoRun(t)
	dir := filepath.Join(r.dir, "my kido")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	bin := filepath.Join(dir, "kido")
	if err := os.Symlink(kidoBin, bin); err != nil {
		t.Fatal(err)
	}

	r.mustOuter("new-window", "-d", "-t", "host", "-n", "first",
		fmt.Sprintf("unset TMUX; exec env %s PATH=/usr/bin:/bin %q", r.envAssign(), bin))
	r.waitUp()
	r.waitFor(func() bool { return r.sidebarUp("first") }, "the side column to be drawn")
	if got, want := r.mustKido("show-options", "-gv", "default-command"), `"`+bin+`" shell`; got != want {
		t.Errorf("default-command = %q, want %q", got, want)
	}
	pane := r.firstPane()
	r.waitFor(func() bool {
		return reportedPrompt(r.mustKido("display-message", "-p", "-t", pane, "#{pane_last_prompt_time}"))
	}, "the pane's shell, started by `kido shell`, to report its first prompt")
}

func TestLauncherWaitsForShellExit(t *testing.T) {
	requireTmux(t)
	if _, err := exec.LookPath("zsh"); err != nil {
		t.Skip("no zsh for the shell exit hook")
	}
	done := filepath.Join(t.TempDir(), "shell-exited")
	var pid string
	t.Run("exit-hook", func(t *testing.T) {
		r := newKidoRun(t)
		rc := fmt.Sprintf(`PS1='kido$ '
TRAPEXIT() {
  local i
  for ((i = 0; i < 2000; i++)); do
    print -r -- "$i" > "$HOME/.exit-progress"
  done
  print -r -- done > %q
}
`, done)
		if err := os.WriteFile(filepath.Join(r.home, ".zshrc"), []byte(rc), 0o644); err != nil {
			t.Fatal(err)
		}
		r.launch("first")
		r.waitUp()
		pane := r.firstPane()
		r.waitFor(func() bool {
			return reportedPrompt(r.mustKido("display-message", "-p", "-t", pane, "#{pane_last_prompt_time}"))
		}, "the shell with an exit hook to report its first prompt")
		pid = r.mustKido("display-message", "-p", "-t", pane, "#{pane_pid}")
	})
	if _, err := os.Stat(done); err != nil {
		t.Error("launcher teardown returned before the shell's HOME writes finished")
	}
	if pid != "" && !processGone(pid, settle) {
		t.Errorf("shell pid %s outlived launcher teardown", pid)
	}
}

func launcherEnv(t *testing.T, extra ...string) []string {
	t.Helper()
	sock, err := os.MkdirTemp("", "kido-sock")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(sock) })
	return cleanEnv(append([]string{"TMUX=", "TMUX_SIDE_CLIENT=", "TMUX_TMPDIR=" + sock,
		"KIDO_STATE_DIR=" + t.TempDir(), "HOME=" + t.TempDir(), "XDG_CONFIG_HOME="}, extra...)...)
}

func writeScript(t *testing.T, path, body string) string {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// The launcher's refusals, each before a server exists: its cause on
// stderr and exit 1.
func TestLauncherRefusals(t *testing.T) {
	t.Parallel()
	requireTmux(t)
	dir := t.TempDir()
	quoted := filepath.Join(dir, "we're here", "kido")
	if err := os.MkdirAll(filepath.Dir(quoted), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(kidoBin, quoted); err != nil {
		t.Fatal(err)
	}
	mismatch := writeScript(t, filepath.Join(dir, "old-tmux"),
		"#!/bin/sh\necho 'protocol version mismatch (client 8, server 7)' >&2\nexit 1\n")
	for _, c := range []struct {
		bin    string
		env    []string
		stderr string
	}{
		{kidoBin, []string{"HOME="}, "kido: $HOME is not defined"},
		{quoted, nil, fmt.Sprintf(`kido: cannot start a kido server: refusing path %q: it contains "'"`, quoted)},
		{kidoBin, []string{"KIDO_TMUX=" + mismatch},
			`kido: the kido server on socket "kido" is running an older kido-tmux than this one`},
	} {
		env := launcherEnv(t, c.env...)
		cmd := exec.Command(c.bin)
		cmd.Env = env
		out, err := cmd.CombinedOutput()
		if code := cmd.ProcessState.ExitCode(); code != 1 || !strings.HasPrefix(string(out), c.stderr) {
			t.Errorf("%s: exit %d (%v), output %q; want exit 1 and %q", c.bin, code, err, out, c.stderr)
		}
		for _, kv := range env {
			if sock, ok := strings.CutPrefix(kv, "TMUX_TMPDIR="); ok {
				if _, err := os.Stat(socketPath(sock, "kido")); err == nil {
					t.Errorf("%s: a server started on %s", c.bin, sock)
				}
			}
		}
	}
}

// Which tmux the launcher runs, and what it does with the probe's answer:
// a stand-in answers list-sessions as told and records what the launcher
// then execs. The one beside a symlinked kido wins over the one beside the
// file it names: only the link's directory survives a Homebrew upgrade.
func TestLauncherFindsItsTmuxAndReadsTheProbe(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	const fake = `#!/bin/sh
if [ "$3" = list-sessions ]; then
  [ -z "$PROBE_ERR" ] || echo "$PROBE_ERR" >&2
  exit "$PROBE_RC"
fi
echo "$0 $*" >"$OUT"
`
	named := writeScript(t, filepath.Join(dir, "named", "fork"), fake)
	beside := filepath.Join(dir, "beside")
	writeScript(t, filepath.Join(beside, "kido-tmux"), fake)
	if err := os.Symlink(kidoBin, filepath.Join(beside, "kido")); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(kidoBin)
	if err != nil {
		t.Fatal(err)
	}
	alone := writeScript(t, filepath.Join(dir, "alone", "kido"), string(body))
	onPath := writeScript(t, filepath.Join(dir, "path", "tmux"), fake)

	attach, start := "-L kido attach-session", "-L kido -f STATE/server.conf new-session -s main"
	for i, c := range []struct {
		bin, env, rc, stderr, tmux, args string
	}{
		{kidoBin, "KIDO_TMUX=" + named, "0", "", named, attach},
		{kidoBin, "KIDO_TMUX=" + named, "1", "no server running on /tmp/tmux-1/kido", named, start},
		{kidoBin, "KIDO_TMUX=" + named, "1", "error connecting to /tmp/tmux-1/kido (No such file or directory)", named, start},
		{filepath.Join(beside, "kido"), "KIDO_TMUX=", "0", "", filepath.Join(beside, "kido-tmux"), attach},
		{alone, "PATH=" + filepath.Dir(onPath) + ":/usr/bin:/bin", "0", "", onPath, attach},
	} {
		out := filepath.Join(dir, fmt.Sprintf("exec-%d", i))
		state := t.TempDir()
		cmd := exec.Command(c.bin)
		cmd.Env = launcherEnv(t, c.env, "PROBE_RC="+c.rc, "PROBE_ERR="+c.stderr, "OUT="+out,
			"KIDO_STATE_DIR="+state)
		if b, err := cmd.CombinedOutput(); err != nil {
			t.Errorf("%s with %s, probe %s: %v\n%s", c.bin, c.env, c.rc, err, b)
			continue
		}
		got, _ := os.ReadFile(out)
		if want := c.tmux + " " + strings.ReplaceAll(c.args, "STATE", state); strings.TrimSpace(string(got)) != want {
			t.Errorf("%s with %s, probe %s %q: ran %q, want %q", c.bin, c.env, c.rc, c.stderr, got, want)
		}
	}
}

// `kido shell` runs tmux's default-shell, which tmux also hands its panes
// as $SHELL: here one it can prime, not the launcher's plain /bin/sh.
func TestKidoConfDefaultShellIsTheLoginShell(t *testing.T) {
	t.Parallel()
	r := newKidoRun(t)
	conf := filepath.Join(r.config, "kido")
	if err := os.MkdirAll(conf, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(conf, "kido.conf"),
		[]byte("set -g default-shell "+r.shell+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r.shell = "/bin/sh"

	r.launch("first")
	r.waitUp()
	pane := r.firstPane()
	r.waitFor(func() bool {
		return reportedPrompt(r.mustKido("display-message", "-p", "-t", pane, "#{pane_last_prompt_time}"))
	}, "the default-shell, primed, to report its first prompt")
}
