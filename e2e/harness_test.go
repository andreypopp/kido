// Package e2e drives kido inside a real tmux fork: an outer tmux server
// gives an inner server a pty client, the inner server runs kido in its
// side status column, and the tests read the rendered column back out of
// the outer server with capture-pane.
//
//	go test ./e2e/ -count=1 -v
//
// KIDO_TMUX picks which tmux the harness tests (default: the "tmux" on
// PATH); it is the harness's own knob and is kept out of every environment
// kido itself runs in, because kido resolves the tmux binary from the
// server it is talking to. The tests skip when no patched tmux is
// available, unless KIDO_E2E_REQUIRED=1.
package e2e

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/x/ansi"
)

var (
	tmuxBin   string // patched tmux, or "" when unusable
	tmuxWhy   string // why it is unusable
	kidoBin   string // freshly built kido
	claudeBin string // a binary named "claude" that just sleeps
)

const (
	sideWidth = 40 // side-status-width; the separator sits at column 40
	outerCols = 200
	outerRows = 50
	settle    = 5 * time.Second // kido polls every 500ms
	// shell is pane_current_command for a bare pane: the inner config
	// pins default-shell to /bin/bash, which exists on both CI runners
	// and on dev machines.
	shell = "bash"
)

func TestMain(m *testing.M) {
	code, err := setup(m)
	if err != nil {
		fmt.Fprintln(os.Stderr, "e2e setup:", err)
		os.Exit(1)
	}
	os.Exit(code)
}

func setup(m *testing.M) (int, error) {
	dir, err := os.MkdirTemp("", "kido-e2e-bin")
	if err != nil {
		return 0, err
	}
	defer os.RemoveAll(dir)

	kidoBin = filepath.Join(dir, "kido")
	if out, err := exec.Command("go", "build", "-o", kidoBin, "kido/cmd/kido").CombinedOutput(); err != nil {
		return 0, fmt.Errorf("go build kido: %v\n%s", err, out)
	}
	if claudeBin, err = buildFakeClaude(dir); err != nil {
		return 0, err
	}
	tmuxBin, tmuxWhy = findTmux()
	return m.Run(), nil
}

// buildFakeClaude compiles a binary called "claude" that sleeps: tmux
// reports it as pane_current_command, which is what kido keys off for
// panes without hook state and for `kido snapshot`. (Copying /bin/sleep
// does not work on macOS: the copy fails its code signature.)
func buildFakeClaude(dir string) (string, error) {
	src := filepath.Join(dir, "fakeclaude")
	if err := os.MkdirAll(src, 0o755); err != nil {
		return "", err
	}
	main := "package main\n\nimport \"time\"\n\nfunc main() { time.Sleep(30 * time.Minute) }\n"
	if err := os.WriteFile(filepath.Join(src, "main.go"), []byte(main), 0o644); err != nil {
		return "", err
	}
	// Building a named file needs no go.mod: the source imports only the
	// standard library.
	out := filepath.Join(dir, "claude")
	cmd := exec.Command("go", "build", "-o", out, "main.go")
	cmd.Dir = src
	if b, err := cmd.CombinedOutput(); err != nil {
		return "", fmt.Errorf("go build fake claude: %v\n%s", err, b)
	}
	return out, nil
}

// cleanEnv is this process's environment with KIDO_TMUX removed, plus
// extra. Everything the harness spawns gets it: KIDO_TMUX would otherwise
// reach kido through the tmux servers it starts, and kido must resolve the
// tmux binary on its own.
func cleanEnv(extra ...string) []string {
	env := make([]string, 0, len(os.Environ())+len(extra))
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "KIDO_TMUX=") {
			env = append(env, kv)
		}
	}
	return append(env, extra...)
}

// findTmux locates a tmux that has the side status column.
func findTmux() (bin, why string) {
	bin = os.Getenv("KIDO_TMUX")
	if bin == "" {
		bin = "tmux"
	}
	path, err := exec.LookPath(bin)
	if err != nil {
		return "", fmt.Sprintf("%s not found in PATH", bin)
	}
	ver, err := exec.Command(path, "-V").Output()
	if err != nil {
		return "", fmt.Sprintf("%s -V: %v", path, err)
	}
	if !strings.Contains(string(ver), "next-3.9") {
		return "", fmt.Sprintf("%s is %q, want the andreypopp/tmux fork (next-3.9)", path, strings.TrimSpace(string(ver)))
	}
	probe := fmt.Sprintf("kido-e2e-probe-%d-%d", os.Getpid(), rand.Int32N(1<<20))
	out, err := exec.Command(path, "-f", "/dev/null", "-L", probe, "start-server", ";",
		"show-options", "-g", "side-status-command", ";",
		"display-message", "-p", "#{socket_path}").CombinedOutput()
	sock := ""
	if lines := strings.Fields(string(out)); len(lines) > 0 {
		sock = lines[len(lines)-1]
	}
	exec.Command(path, "-L", probe, "kill-server").Run()
	if sock != "" {
		os.Remove(sock)
	}
	if err != nil {
		return "", fmt.Sprintf("%s has no side-status-command: %v\n%s", path, err, out)
	}
	return path, ""
}

// requireTmux skips (or fails, with KIDO_E2E_REQUIRED=1) when the patched
// tmux is missing.
func requireTmux(t *testing.T) {
	t.Helper()
	if tmuxBin != "" {
		return
	}
	if os.Getenv("KIDO_E2E_REQUIRED") == "1" {
		t.Fatal("KIDO_E2E_REQUIRED=1 but no patched tmux: " + tmuxWhy)
	}
	t.Skip("no patched tmux: " + tmuxWhy)
}

// ---- harness ---------------------------------------------------------------

// harness is one pair of tmux servers: "outer" hosts a pty, "inner" is the
// server under test whose client lives in that pty and whose side status
// column runs kido.
type harness struct {
	t        *testing.T
	dir      string // scratch: config, state, session working directory
	stateDir string
	outer    string // outer socket name
	inner    string // inner socket name
	client   string // the inner client's name, e.g. /dev/ttys012
	proxy    string // ssh ProxyCommand script, written on demand
}

var sanitize = regexp.MustCompile(`[^A-Za-z0-9]+`)

// start brings up both servers with one inner session and waits until the
// sidebar has rendered it.
func start(t *testing.T, session string) *harness {
	t.Helper()
	requireTmux(t)

	h := &harness{t: t, dir: t.TempDir()}
	// The socket names must not collide with a server another run left
	// behind, so they carry the pid and a random tag.
	name := fmt.Sprintf("%s-%d-%d", sanitize.ReplaceAllString(t.Name(), "-"),
		os.Getpid(), rand.Int32N(1<<20))
	h.outer = "kido-o-" + name
	h.inner = "kido-i-" + name
	h.stateDir = filepath.Join(h.dir, "state")
	if err := os.MkdirAll(h.stateDir, 0o755); err != nil {
		t.Fatal(err)
	}

	conf := filepath.Join(h.dir, "inner.conf")
	body := fmt.Sprintf(`
set -g status off
set -sg escape-time 0
set -g default-shell /bin/bash
set -g default-command ""
set -g side-status left
set -g side-status-width %d
set -g side-status-style "fg=default,bg=default"
set -g side-status-command "KIDO_STATE_DIR=%s %s"
set -g mouse on
bind-key K if-shell -F '#{==:#{side-status},off}' \
  'set -g side-status left ; refresh-client -f side-status-focus' \
  'set -g side-status off'
bind-key k if-shell -F '#{m:*side-status-focus*,#{client_flags}}' \
  'refresh-client -f !side-status-focus' \
  'refresh-client -f side-status-focus'
`, sideWidth, h.stateDir, kidoBin)
	if err := os.WriteFile(conf, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	t.Cleanup(func() {
		killServer(h.inner)
		killServer(h.outer)
	})

	h.must(h.tmux(h.outer, "-f", "/dev/null", "new-session", "-d", "-s", "host",
		"-x", strconv.Itoa(outerCols), "-y", strconv.Itoa(outerRows)))
	// CI no longer installs ncurses-term, so screen-256color (always
	// present) is the only terminfo the inner tmux can open on Ubuntu.
	h.must(h.tmux(h.outer, "set-option", "-g", "default-terminal", "screen-256color"))
	// remain-on-exit keeps a dead client's error on screen, not vanishing.
	h.must(h.tmux(h.outer, "set-option", "-g", "remain-on-exit", "on"))
	inner := fmt.Sprintf("unset TMUX; exec %q -L %s -f %q new-session -s %s -c %q",
		tmuxBin, h.inner, conf, session, h.dir)
	h.must(h.tmux(h.outer, "new-window", "-d", "-t", "host", "-n", "side", inner))

	h.waitFor(func() bool { return hasLine(h.sidebar(), session) }, settle,
		msgf("sidebar shows session %s", session))
	h.client = strings.TrimSpace(strings.Split(h.in("list-clients", "-F", "#{client_name}"), "\n")[0])
	return h
}

// killServer stops a test server and unlinks its socket, which tmux
// sometimes leaves behind in the shared socket directory.
func killServer(socket string) {
	path, err := exec.Command(tmuxBin, "-L", socket, "display-message", "-p", "#{socket_path}").Output()
	exec.Command(tmuxBin, "-L", socket, "kill-server").Run()
	if err == nil {
		os.Remove(strings.TrimSpace(string(path)))
	}
}

// ---- running tmux ----------------------------------------------------------

func (h *harness) tmux(socket string, args ...string) (string, error) {
	full := append([]string{"-L", socket}, args...)
	cmd := exec.Command(tmuxBin, full...)
	cmd.Env = cleanEnv("TMUX=")
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		return out.String(), fmt.Errorf("tmux -L %s %s: %v: %s",
			socket, strings.Join(args, " "), err, strings.TrimSpace(errb.String()))
	}
	return strings.TrimRight(out.String(), "\n"), nil
}

func (h *harness) must(out string, err error) string {
	h.t.Helper()
	if err != nil {
		h.t.Fatal(err)
	}
	return out
}

// in runs a command on the inner server (the one under test).
func (h *harness) in(args ...string) string {
	h.t.Helper()
	return h.must(h.tmux(h.inner, args...))
}

// out runs a command on the outer server (the one holding the pty).
func (h *harness) out(args ...string) string {
	h.t.Helper()
	return h.must(h.tmux(h.outer, args...))
}

// ---- keys ------------------------------------------------------------------

// sendKeys sends keys to the inner client's pty, one send-keys call per
// key: tmux drops keys batched with the prefix.
func (h *harness) sendKeys(keys ...string) {
	h.t.Helper()
	for _, k := range keys {
		h.out("send-keys", "-t", "host:side", k)
		time.Sleep(60 * time.Millisecond)
	}
}

// sendLiteral types text as-is.
func (h *harness) sendLiteral(s string) {
	h.t.Helper()
	h.out("send-keys", "-t", "host:side", "-l", s)
	time.Sleep(60 * time.Millisecond)
}

// prefix sends the tmux prefix (C-b) followed by key.
func (h *harness) prefix(key string) {
	h.t.Helper()
	h.sendKeys("C-b")
	h.sendKeys(key)
}

// ---- mouse -----------------------------------------------------------------

// SGR mouse reports; x and y are 1-based screen coordinates.
func (h *harness) mouseSeq(b, x, y int, press bool) {
	h.t.Helper()
	end := "m"
	if press {
		end = "M"
	}
	h.out("send-keys", "-t", "host:side", "-l",
		fmt.Sprintf("\x1b[<%d;%d;%d%s", b, x, y, end))
	time.Sleep(60 * time.Millisecond)
}

func (h *harness) click(x, y int) {
	h.t.Helper()
	h.mouseSeq(0, x, y, true)
	h.mouseSeq(0, x, y, false)
}

func (h *harness) wheelUp(x, y int)   { h.t.Helper(); h.mouseSeq(64, x, y, true) }
func (h *harness) wheelDown(x, y int) { h.t.Helper(); h.mouseSeq(65, x, y, true) }

// drag presses at fromX, moves through the intermediate columns and
// releases at toX, all on row y.
func (h *harness) drag(fromX, toX, y int) {
	h.t.Helper()
	h.mouseSeq(0, fromX, y, true)
	step := 3
	if toX < fromX {
		step = -3
	}
	for x := fromX + step; (step > 0 && x < toX) || (step < 0 && x > toX); x += step {
		h.mouseSeq(32, x, y, true)
	}
	h.mouseSeq(32, toX, y, true)
	h.mouseSeq(0, toX, y, false)
}

// ---- reading the screen ----------------------------------------------------

// reverseRE matches an SGR escape that turns on reverse video (parameter
// 7), tolerating tmux combining it with other attributes in the same
// escape ("\x1b[1;7m") rather than requiring a literal "\x1b[7m".
var reverseRE = regexp.MustCompile(`\x1b\[(?:\d+;)*7(?:;\d+)*m`)

// sgrOn holds, per SGR parameter the tests read, a matcher for an escape
// that turns that attribute on. Built once so it is safe to share between
// parallel tests.
var sgrOn = map[string]*regexp.Regexp{
	"7": reverseRE,                                        // reverse video: the selected row
	"1": regexp.MustCompile(`\x1b\[(?:\d+;)*1(?:;\d+)*m`), // bold: the client's session
}

// hasSGR reports whether line switches on the SGR attribute param.
func hasSGR(line, param string) bool {
	re, ok := sgrOn[param]
	if !ok {
		panic("hasSGR: no matcher for SGR parameter " + param)
	}
	return re.MatchString(line)
}

// capture returns the outer pane's screen with escape sequences kept.
func (h *harness) capture() []string {
	h.t.Helper()
	out, err := h.tmux(h.outer, "capture-pane", "-p", "-e", "-t", "host:side")
	if err != nil {
		return nil
	}
	return strings.Split(out, "\n")
}

// sideOf cuts the side column (everything left of the separator) out of a
// captured line, escape sequences and all. The separator rune cannot occur
// inside an escape, so cutting before stripping is safe and keeps the
// window area's attributes out of the SGR checks.
func sideOf(line string) string {
	if i := strings.IndexRune(line, '│'); i >= 0 {
		return line[:i]
	}
	return line
}

// sideText is one captured line as the side column's plain text.
func sideText(line string) string { return strings.TrimSpace(ansi.Strip(sideOf(line))) }

// sidebarOf is sideText over a captured screen.
func sidebarOf(lines []string) []string {
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		out = append(out, sideText(line))
	}
	return out
}

// sidebar returns the side column's text lines.
func (h *harness) sidebar() []string { return sidebarOf(h.capture()) }

// separatorAt reports whether the column separator sits at column w.
func (h *harness) separatorAt(w int) bool {
	h.t.Helper()
	for _, line := range h.capture() {
		r := []rune(ansi.Strip(line))
		if len(r) >= w && r[w-1] == '│' {
			return true
		}
	}
	return false
}

// sidebarVisible reports whether the column's separator line is on screen:
// with the column hidden the window area starts at the first column.
func (h *harness) sidebarVisible() bool { return h.separatorAt(sideWidth) }

// rowsOf keeps the non-empty side column lines of a captured screen.
func rowsOf(lines []string) []string {
	var out []string
	for _, l := range sidebarOf(lines) {
		if l != "" {
			out = append(out, l)
		}
	}
	return out
}

// rows returns the non-empty side column lines.
func (h *harness) rows() []string { return rowsOf(h.capture()) }

// selectedRowOf returns the text of the row kido draws in reverse video.
func selectedRowOf(lines []string) string {
	for _, line := range lines {
		if hasSGR(sideOf(line), "7") {
			return sideText(line)
		}
	}
	return ""
}

// selectedIndexOf is the screen line (1-based, as the mouse counts) of the
// reverse-video row, or 0.
func selectedIndexOf(lines []string) int {
	for i, line := range lines {
		if hasSGR(sideOf(line), "7") {
			return i + 1
		}
	}
	return 0
}

func (h *harness) selectedRow() string { h.t.Helper(); return selectedRowOf(h.capture()) }
func (h *harness) selectedIndex() int  { h.t.Helper(); return selectedIndexOf(h.capture()) }

// waitSelectedLine waits until the reverse-video row is screen line n.
func (h *harness) waitSelectedLine(n int) {
	h.t.Helper()
	h.waitFor(func() bool { return h.selectedIndex() == n }, settle, func() string {
		lines := h.capture()
		return fmt.Sprintf("selection on line %d (is %d: %q)", n,
			selectedIndexOf(lines), selectedRowOf(lines))
	})
}

// isBold reports whether the sidebar line containing sub is rendered bold.
func (h *harness) isBold(sub string) bool {
	h.t.Helper()
	for _, line := range h.capture() {
		if strings.Contains(sideText(line), sub) {
			return hasSGR(sideOf(line), "1")
		}
	}
	return false
}

func hasLine(lines []string, sub string) bool {
	for _, l := range lines {
		if strings.Contains(l, sub) {
			return true
		}
	}
	return false
}

// rowIndexOf is the screen row (1-based, as the mouse counts) of the first
// side column line containing sub, or 0.
func rowIndexOf(lines []string, sub string) int {
	for i, l := range sidebarOf(lines) {
		if strings.Contains(l, sub) {
			return i + 1
		}
	}
	return 0
}

func (h *harness) rowIndex(sub string) int { return rowIndexOf(h.capture(), sub) }

// ---- waiting ---------------------------------------------------------------

// msgf is a waitFor description that is only formatted if the wait fails.
func msgf(format string, a ...any) func() string {
	return func() string { return fmt.Sprintf(format, a...) }
}

// waitFor polls cond until it holds or timeout passes. describe is called
// only on failure, so a description that reads the screen costs nothing
// while polling and reports the state at the deadline.
func (h *harness) waitFor(cond func() bool, timeout time.Duration, describe func() string) {
	h.t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		if cond() {
			return
		}
		if time.Now().After(deadline) {
			h.t.Fatalf("timed out waiting for %s\n%s", describe(), h.diagnose())
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// diagnose renders a compact snapshot of both servers for a failed
// waitFor: what the outer pane shows (with the escapes tmux emitted made
// visible), whether that pane died and why, and the inner server's
// sessions.
func (h *harness) diagnose() string {
	h.t.Helper()
	var b strings.Builder

	fmt.Fprintln(&b, "outer capture (escapes as ^[):")
	for i, l := range h.capture() {
		if i == 12 {
			break
		}
		fmt.Fprintln(&b, "  "+strings.ReplaceAll(l, "\x1b", "^["))
	}
	// h.in and friends would fail the test from inside diagnose(); go
	// straight through h.tmux, which only returns an error.
	report := func(label string, args ...string) {
		out, err := h.tmux(h.inner, args...)
		if err != nil {
			fmt.Fprintf(&b, "%s: error: %v\n", label, err)
			return
		}
		fmt.Fprintf(&b, "%s:\n  %s\n", label, strings.ReplaceAll(out, "\n", "\n  "))
	}
	if out, err := h.tmux(h.outer, "display-message", "-p", "-t", "host:side",
		"#{pane_dead} #{pane_dead_status} #{pane_current_command}"); err != nil {
		fmt.Fprintf(&b, "outer pane status: error: %v\n", err)
	} else {
		fmt.Fprintf(&b, "outer pane status (dead deadstatus cmd): %s\n", out)
	}
	report("inner list-sessions", "list-sessions")
	return b.String()
}

// waitRow waits until a sidebar line contains sub.
func (h *harness) waitRow(sub string) {
	h.t.Helper()
	h.waitFor(func() bool { return hasLine(h.sidebar(), sub) }, settle,
		msgf("row %q", sub))
}

// waitRows waits until the column holds exactly n non-empty rows.
func (h *harness) waitRows(n int) {
	h.t.Helper()
	h.waitFor(func() bool { return len(h.rows()) == n }, settle, func() string {
		return fmt.Sprintf("%d rows (are %q)", n, h.rows())
	})
}

// waitSelected waits until the reverse-video row contains sub.
func (h *harness) waitSelected(sub string) {
	h.t.Helper()
	h.waitFor(func() bool { return strings.Contains(h.selectedRow(), sub) }, settle,
		func() string { return fmt.Sprintf("selection on %q (is %q)", sub, h.selectedRow()) })
}

// ---- client state ----------------------------------------------------------

func (h *harness) clientSession() string {
	h.t.Helper()
	out := h.in("list-clients", "-F", "#{client_name}\t#{client_session}")
	for _, line := range strings.Split(out, "\n") {
		name, sess, _ := strings.Cut(line, "\t")
		if name == h.client {
			return sess
		}
	}
	return ""
}

func (h *harness) clientFocused() bool {
	h.t.Helper()
	out := h.in("list-clients", "-F", "#{client_name}\t#{client_flags}")
	for _, line := range strings.Split(out, "\n") {
		name, flags, _ := strings.Cut(line, "\t")
		if name == h.client {
			return strings.Contains(flags, "side-status-focus")
		}
	}
	return false
}

func (h *harness) waitSession(name string) {
	h.t.Helper()
	h.waitFor(func() bool { return h.clientSession() == name }, settle,
		msgf("client attached to %s", name))
}

func (h *harness) waitFocused(want bool) {
	h.t.Helper()
	h.waitFor(func() bool { return h.clientFocused() == want }, settle,
		msgf("side-status-focus = %v", want))
}

// ---- inner server helpers --------------------------------------------------

type paneInfo struct {
	Session string
	Window  string
	ID      string
	Command string
	Title   string
	Active  bool
}

func (h *harness) panes() []paneInfo {
	h.t.Helper()
	out := h.in("list-panes", "-a", "-F",
		"#{session_name}\t#{window_index}\t#{pane_id}\t#{pane_current_command}\t#{pane_active}\t#{pane_title}")
	var ps []paneInfo
	for _, line := range strings.Split(out, "\n") {
		f := strings.SplitN(line, "\t", 6)
		if len(f) < 6 {
			continue
		}
		ps = append(ps, paneInfo{Session: f[0], Window: f[1], ID: f[2],
			Command: f[3], Active: f[4] == "1", Title: f[5]})
	}
	return ps
}

// newSession creates an inner session and waits for it in the sidebar.
func (h *harness) newSession(name string) {
	h.t.Helper()
	h.in("new-session", "-d", "-s", name, "-c", h.dir)
	h.waitRow(name)
}

// newWindow opens a window in session (named name, if any) running argv,
// and returns its pane id. argv is always passed as separate arguments so
// tmux execs it directly; a lone command word is instead routed through
// the pane's shell (spawn.c execs only for argc > 1), which on some
// shells stays the pane's foreground process and hides the real command
// from pane_current_command. Pass no argv at all for a plain shell pane.
func (h *harness) newWindow(session, name string, argv ...string) string {
	h.t.Helper()
	if len(argv) == 1 {
		h.t.Fatalf("newWindow(%q, %q, %q): a one-word command is run through the pane's "+
			"shell, not exec'd; add an argument the command ignores, or pass "+
			"\"sh\", \"-c\", \"exec %s\"", session, name, argv[0], argv[0])
	}
	args := []string{"new-window", "-P", "-F", "#{pane_id}", "-d", "-t", session + ":"}
	if name != "" {
		args = append(args, "-n", name)
	}
	return h.in(append(args, argv...)...)
}

// waitPaneCommand waits until pane id runs cmd as its foreground process.
func (h *harness) waitPaneCommand(id, cmd string) {
	h.t.Helper()
	h.waitFor(func() bool {
		for _, p := range h.panes() {
			if p.ID == id {
				return p.Command == cmd
			}
		}
		return false
	}, settle, msgf("pane %s running %s", id, cmd))
}

// sshProxy writes (once per harness) a ProxyCommand script that just
// blocks, so an ssh pane needs no network. It is a script rather than
// "sleep 300" because kido reads ssh's arguments out of ps output, where a
// space inside an option value is indistinguishable from an argument
// separator.
func (h *harness) sshProxy() string {
	h.t.Helper()
	if h.proxy == "" {
		p := filepath.Join(h.dir, "proxy")
		if err := os.WriteFile(p, []byte("#!/bin/sh\nexec sleep 300\n"), 0o755); err != nil {
			h.t.Fatal(err)
		}
		h.proxy = p
	}
	return h.proxy
}

// ---- the kido hook ---------------------------------------------------------

// hook runs `kido hook` with the payload built from event and the extra
// key/value pairs, reporting for pane. The hook records its parent pid,
// which is this test binary: alive for the whole run, so the state file
// stays valid.
func (h *harness) hook(sessionID, pane, event string, kv ...string) {
	h.t.Helper()
	payload := map[string]string{"hook_event_name": event, "session_id": sessionID}
	for i := 0; i+1 < len(kv); i += 2 {
		payload[kv[i]] = kv[i+1]
	}
	body, err := json.Marshal(payload)
	if err != nil {
		h.t.Fatal(err)
	}
	cmd := exec.Command(kidoBin, "hook")
	cmd.Stdin = bytes.NewReader(body)
	cmd.Env = cleanEnv("TMUX_PANE="+pane, "KIDO_STATE_DIR="+h.stateDir)
	if out, err := cmd.CombinedOutput(); err != nil {
		h.t.Fatalf("kido hook %s: %v\n%s", event, err, out)
	}
}

// claudePane opens a window in session running the fake claude binary and
// titles it, so the pane looks like a Claude Code pane to kido. The "--"
// is the ignored argument newWindow insists on.
func (h *harness) claudePane(session, title string) string {
	h.t.Helper()
	id := h.newWindow(session, "", claudeBin, "--")
	h.waitPaneCommand(id, "claude")
	h.title(id, title)
	return id
}

// title names a pane the way Claude Code does ("✳ <name>"). A shell in the
// pane rewrites the title from its prompt, so keep setting it until it
// sticks.
func (h *harness) title(pane, title string) {
	h.t.Helper()
	h.waitFor(func() bool {
		for _, p := range h.panes() {
			if p.ID == pane && p.Title == title {
				return true
			}
		}
		h.in("select-pane", "-t", pane, "-T", title)
		return false
	}, settle, msgf("pane %s titled %s", pane, title))
}
