// Package e2e drives kido inside a real tmux fork: an outer tmux server
// gives an inner server a pty client, the inner server runs kido in its
// side status column, and the tests read the rendered column back out of
// the outer server with capture-pane.
//
//	go test ./e2e/ -count=1 -v
//
// Set KIDO_TMUX to the patched tmux if it is not the "tmux" on PATH. The
// tests skip when no patched tmux is available, unless KIDO_E2E_REQUIRED=1.
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
	files := map[string]string{
		"go.mod":  "module fakeclaude\n\ngo 1.27\n",
		"main.go": "package main\n\nimport \"time\"\n\nfunc main() { time.Sleep(30 * time.Minute) }\n",
	}
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(src, name), []byte(body), 0o644); err != nil {
			return "", err
		}
	}
	out := filepath.Join(dir, "claude")
	cmd := exec.Command("go", "build", "-o", out, ".")
	cmd.Dir = src
	if b, err := cmd.CombinedOutput(); err != nil {
		return "", fmt.Errorf("go build fake claude: %v\n%s", err, b)
	}
	return out, nil
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
	shell    string // pane_current_command of a bare shell pane on this platform
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
set -g default-shell /bin/sh
set -g default-command ""
set -g side-status left
set -g side-status-width %d
set -g side-status-style "fg=default,bg=default"
set -g side-status-command "KIDO_STATE_DIR=%s KIDO_TMUX=%s %s"
set -g mouse on
bind-key K if-shell -F '#{==:#{side-status},off}' \
  'set -g side-status left ; refresh-client -f side-status-focus' \
  'set -g side-status off'
bind-key k if-shell -F '#{m:*side-status-focus*,#{client_flags}}' \
  'refresh-client -f !side-status-focus' \
  'refresh-client -f side-status-focus'
`, sideWidth, h.stateDir, tmuxBin, kidoBin)
	if err := os.WriteFile(conf, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	t.Cleanup(func() {
		killServer(h.inner)
		killServer(h.outer)
	})

	h.must(h.tmux(h.outer, "-f", "/dev/null", "new-session", "-d", "-s", "host",
		"-x", strconv.Itoa(outerCols), "-y", strconv.Itoa(outerRows)))
	// Ubuntu runners lack the tmux-256color terminfo (it ships in the
	// ncurses-term package, not installed by default); without it the
	// inner tmux started below fails with "open terminal failed" and its
	// pane exits immediately, leaving the sidebar blank. screen-256color
	// is always present. remain-on-exit keeps a dead inner client's error
	// text on screen instead of the pane vanishing, so failures are
	// diagnosable.
	h.must(h.tmux(h.outer, "set-option", "-g", "default-terminal", "screen-256color"))
	h.must(h.tmux(h.outer, "set-option", "-g", "remain-on-exit", "on"))
	inner := fmt.Sprintf("unset TMUX; exec %q -L %s -f %q new-session -s %s -c %q",
		tmuxBin, h.inner, conf, session, h.dir)
	h.must(h.tmux(h.outer, "new-window", "-d", "-t", "host", "-n", "side", inner))

	h.waitFor(func() bool { return hasLine(h.sidebar(), session) }, settle,
		"sidebar shows session "+session)
	h.client = h.clientName()
	// default-shell is forced to /bin/sh above so panes don't depend on the
	// runner's login shell, but what that reports as pane_current_command
	// is itself platform-dependent (e.g. macOS's /bin/sh re-execs the real
	// /bin/bash, so it reads "bash"; Ubuntu's is dash and reads "sh").
	// Probe it once per harness instead of hard-coding a name.
	for _, p := range h.panes() {
		if p.Session == session {
			h.shell = p.Command
			break
		}
	}
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
	cmd.Env = append(os.Environ(), "TMUX=")
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
	time.Sleep(150 * time.Millisecond)
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
	time.Sleep(150 * time.Millisecond)
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
	time.Sleep(300 * time.Millisecond)
}

// ---- reading the screen ----------------------------------------------------

var ansiRE = regexp.MustCompile(`\x1b\[[0-9;:?]*[ -/]*[@-~]`)

func stripANSI(s string) string { return ansiRE.ReplaceAllString(s, "") }

// capture returns the outer pane's screen with escape sequences kept.
func (h *harness) capture() []string {
	h.t.Helper()
	out, err := h.tmux(h.outer, "capture-pane", "-p", "-e", "-t", "host:side")
	if err != nil {
		return nil
	}
	return strings.Split(out, "\n")
}

// sidebarOf cuts the side column (everything left of the separator) out of
// a captured screen and strips colours.
func sidebarOf(lines []string) []string {
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		text := stripANSI(line)
		if i := strings.IndexRune(text, '│'); i >= 0 {
			text = text[:i]
		}
		out = append(out, strings.TrimRight(text, " "))
	}
	return out
}

// sidebar returns the side column's text lines.
func (h *harness) sidebar() []string { return sidebarOf(h.capture()) }

// sidebarVisible reports whether the column's separator line is on screen:
// with the column hidden the window area starts at the first column.
func (h *harness) sidebarVisible() bool {
	h.t.Helper()
	for _, line := range h.capture() {
		r := []rune(stripANSI(line))
		if len(r) >= sideWidth && r[sideWidth-1] == '│' {
			return true
		}
	}
	return false
}

// sidebarText returns the non-empty side column lines.
func (h *harness) rows() []string {
	var out []string
	for _, l := range h.sidebar() {
		if strings.TrimSpace(l) != "" {
			out = append(out, l)
		}
	}
	return out
}

// selectedRow returns the text of the row kido draws in reverse video.
func (h *harness) selectedRow() string {
	h.t.Helper()
	for _, line := range h.capture() {
		if !strings.Contains(line, "\x1b[7m") {
			continue
		}
		text := stripANSI(line)
		if i := strings.IndexRune(text, '│'); i >= 0 {
			text = text[:i]
		}
		return strings.TrimSpace(text)
	}
	return ""
}

// selectedIndex is the screen line (1-based, as the mouse counts) of the
// reverse-video row, or 0.
func (h *harness) selectedIndex() int {
	h.t.Helper()
	for i, line := range h.capture() {
		if strings.Contains(line, "\x1b[7m") {
			return i + 1
		}
	}
	return 0
}

// waitSelectedLine waits until the reverse-video row is screen line n.
func (h *harness) waitSelectedLine(n int) {
	h.t.Helper()
	h.waitFor(func() bool { return h.selectedIndex() == n }, settle,
		fmt.Sprintf("selection on line %d (is %d: %q)", n, h.selectedIndex(), h.selectedRow()))
}

// isBold reports whether the sidebar line containing sub is rendered bold.
func (h *harness) isBold(sub string) bool {
	h.t.Helper()
	for _, line := range h.capture() {
		text := stripANSI(line)
		if i := strings.IndexRune(text, '│'); i >= 0 {
			text = text[:i]
		}
		if strings.Contains(text, sub) {
			return strings.Contains(line, "\x1b[1m")
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

// rowIndex is the screen row (1-based, as the mouse counts) of the first
// sidebar line containing sub, or 0.
func (h *harness) rowIndex(sub string) int {
	for i, l := range h.sidebar() {
		if strings.Contains(l, sub) {
			return i + 1
		}
	}
	return 0
}

// ---- waiting ---------------------------------------------------------------

func (h *harness) waitFor(cond func() bool, timeout time.Duration, msg string) {
	h.t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		if cond() {
			return
		}
		if time.Now().After(deadline) {
			h.t.Fatalf("timed out waiting for %s\n%s", msg, h.diagnose())
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// diagnose renders a compact snapshot of both servers for a failed waitFor:
// the outer pane's full capture, whether its pane died and why, and the
// inner server's session list (or the error reaching it). Capped at ~30
// lines total.
func (h *harness) diagnose() string {
	h.t.Helper()
	var b strings.Builder

	fmt.Fprintln(&b, "outer capture:")
	capLines := h.capture()
	if len(capLines) > 20 {
		capLines = capLines[:20]
	}
	for _, l := range capLines {
		fmt.Fprintln(&b, "  "+l)
	}

	status, err := h.tmux(h.outer, "display-message", "-p", "-t", "host:side",
		"#{pane_dead} #{pane_dead_status} #{pane_current_command}")
	if err != nil {
		fmt.Fprintf(&b, "outer pane status: error: %v\n", err)
	} else {
		fmt.Fprintf(&b, "outer pane status (dead deadstatus cmd): %s\n", status)
	}

	sessions, err := h.tmux(h.inner, "list-sessions")
	if err != nil {
		fmt.Fprintf(&b, "inner list-sessions: error: %v\n", err)
	} else {
		fmt.Fprintf(&b, "inner list-sessions:\n  %s\n", strings.ReplaceAll(sessions, "\n", "\n  "))
	}

	return b.String()
}

// waitRow waits until a sidebar line contains sub.
func (h *harness) waitRow(sub string) {
	h.t.Helper()
	h.waitFor(func() bool { return hasLine(h.sidebar(), sub) }, settle, "row "+strconv.Quote(sub))
}

// waitSelected waits until the reverse-video row contains sub.
func (h *harness) waitSelected(sub string) {
	h.t.Helper()
	h.waitFor(func() bool { return strings.Contains(h.selectedRow(), sub) }, settle,
		"selection on "+strconv.Quote(sub)+" (is "+strconv.Quote(h.selectedRow())+")")
}

// ---- client state ----------------------------------------------------------

func (h *harness) clientName() string {
	h.t.Helper()
	out := h.in("list-clients", "-F", "#{client_name}")
	return strings.TrimSpace(strings.Split(out, "\n")[0])
}

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
		"client attached to "+name)
}

func (h *harness) waitFocused(want bool) {
	h.t.Helper()
	h.waitFor(func() bool { return h.clientFocused() == want }, settle,
		fmt.Sprintf("side-status-focus = %v", want))
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

// paneOf returns the id of session's first pane.
func (h *harness) paneOf(session string) string {
	h.t.Helper()
	for _, p := range h.panes() {
		if p.Session == session {
			return p.ID
		}
	}
	h.t.Fatalf("no pane in session %q", session)
	return ""
}

// newSession creates an inner session and waits for it in the sidebar.
func (h *harness) newSession(name string) {
	h.t.Helper()
	h.in("new-session", "-d", "-s", name, "-c", h.dir)
	h.waitRow(name)
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
	cmd.Env = append(os.Environ(), "TMUX_PANE="+pane, "KIDO_STATE_DIR="+h.stateDir)
	if out, err := cmd.CombinedOutput(); err != nil {
		h.t.Fatalf("kido hook %s: %v\n%s", event, err, out)
	}
}

// claudePane opens a window in session running the fake claude binary and
// titles it, so the pane looks like a Claude Code pane to kido.
func (h *harness) claudePane(session, title string) string {
	h.t.Helper()
	id := h.in("new-window", "-P", "-F", "#{pane_id}", "-d", "-t", session+":", claudeBin)
	h.waitFor(func() bool {
		for _, p := range h.panes() {
			if p.ID == id && p.Command == "claude" {
				return true
			}
		}
		return false
	}, settle, "pane "+id+" running claude")
	h.title(id, title)
	return id
}

// title names a pane the way Claude Code does ("✳ <name>"). A shell in the
// pane rewrites the title from its prompt, so keep setting it until it
// sticks.
func (h *harness) title(pane, title string) {
	h.t.Helper()
	h.waitFor(func() bool {
		h.in("select-pane", "-t", pane, "-T", title)
		time.Sleep(200 * time.Millisecond)
		for _, p := range h.panes() {
			if p.ID == pane {
				return p.Title == title
			}
		}
		return false
	}, settle, "pane "+pane+" titled "+title)
}
