// Package e2e drives kido inside a real tmux fork: an outer tmux server
// gives an inner server a pty client, the inner server runs kido in its
// side status column, and the tests read the rendered column back out of
// the outer server with capture-pane.
//
//	go test ./test_e2e/ -count=1 -v
//
// KIDO_TMUX picks which tmux the harness tests (default: the "tmux" on
// PATH); it is the harness's own knob and is kept out of every environment
// kido itself runs in, so kido resolves the tmux binary the way an install
// does: through a "kido-tmux" sibling, which setup() symlinks beside the
// built kidoBin to point at that same patched tmux. The tests skip when no
// patched tmux is available, unless KIDO_E2E_REQUIRED=1.
package e2e

import (
	"bytes"
	"cmp"
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
	shareDir  string // the share/kido beside it
	claudeBin string // a binary named "claude" that just sleeps
	nodeBin   string // the same binary named "node", for a pi pane
	piBinDir  string // a directory holding one binary, named "pi"
	tmuxDir   string // a directory holding one binary, named "tmux", the patched fork
	// serverPathPrefix is the PATH prefix every inner server gets: the built
	// kido's directory, so a bare "kido" in share/tmux/kido-tmux.conf's bindings
	// resolves to the binary this harness just built rather than to
	// whatever is installed on the machine running the suite (or nothing,
	// on CI) - mirroring what launch (lib/launch.ml) does for a
	// real launch - plus tmuxDir, for the one binding that runs a literal
	// "tmux" (the C-s popup).
	serverPathPrefix string
)

const (
	sideWidth = 40 // side-status-width; the separator sits at column 40
	outerCols = 200
	outerRows = 50
	settle    = 5 * time.Second // kido polls every 100ms
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
	if bin := os.Getenv("KIDO_TMUX"); bin != "" {
		cmd := exec.Command("git", "ls-files", "-s", "third_party/tmux")
		cmd.Dir = ".."
		pin, err := cmd.Output()
		if err != nil {
			return 0, fmt.Errorf("read pinned tmux revision: %w", err)
		}
		fields := strings.Fields(string(pin))
		if len(fields) != 4 {
			return 0, fmt.Errorf("invalid tmux gitlink: %q", pin)
		}
		path, err := exec.LookPath(bin)
		if err != nil {
			return 0, err
		}
		path, err = filepath.EvalSymlinks(path)
		if err != nil {
			return 0, err
		}
		stamp := filepath.Join(filepath.Dir(path), "..", "share", "kido-tmux", "REVISION")
		revision, err := os.ReadFile(stamp)
		if err != nil {
			return 0, fmt.Errorf("tmux fork REVISION missing at %s: rebuild with scripts/install-tmux-fork.sh: %w", stamp, err)
		}
		if strings.TrimSpace(string(revision)) != fields[1] {
			return 0, fmt.Errorf("tmux fork revision %q differs from pin %s; rebuild with scripts/install-tmux-fork.sh", strings.TrimSpace(string(revision)), fields[1])
		}
	}
	dir, err := os.MkdirTemp("", "kido-e2e-bin")
	if err != nil {
		return 0, err
	}
	defer os.RemoveAll(dir)

	// kido is laid out as an install lays it out, <prefix>/bin beside
	// <prefix>/share/kido, so a kido pane gets the bin directory's shims
	// and a shim finds the kido and kido-tmux it works back to.
	if err := installKido(dir); err != nil {
		return 0, err
	}
	kidoBin = filepath.Join(dir, "bin", "kido")
	shareDir = filepath.Join(dir, "share", "kido")
	if claudeBin, err = buildFakeAgent(dir, dir, "claude"); err != nil {
		return 0, err
	}
	// pi is a bash shim around node, so tmux reports a pi pane as "node".
	// A pane running this one is a pi pane to kido only through what pi
	// reports with `kido agent-status`, which is what the tests drive.
	if nodeBin, err = buildFakeAgent(dir, dir, "node"); err != nil {
		return 0, err
	}
	// A resume that names no command defaults to "pi" (lib/spawn_subagent.ml),
	// which is where the tool allowlist is spelled onto the command line -
	// so that one fixture needs the literal name "pi" to resolve, not a
	// fake standing in under some other name. The only way to make a name
	// resolve is to put its directory on a PATH, so this fake gets a
	// directory holding nothing else: a directory holding the others too
	// would shadow whatever real "node", "claude" or "kido" is installed
	// on the machine running the suite, for every pane that inherits that
	// PATH, and a shell startup file that runs one of those names (nvm's,
	// on a GitHub Ubuntu runner, runs `node -v`) would hang on a fake that
	// never exits. TestSpawnResumeCarriesToolsOntoThePiCommandLine puts
	// this directory on its own server's PATH and nobody else's.
	piBinDir = filepath.Join(dir, "pi-bin")
	if err := os.MkdirAll(piBinDir, 0o755); err != nil {
		return 0, err
	}
	if _, err = buildFakeAgent(dir, piBinDir, "pi"); err != nil {
		return 0, err
	}
	tmuxBin, tmuxWhy = findTmux()
	// A production kido resolves the tmux binary through a "kido-tmux"
	// sibling (Tmux.Exec.resolve_binary); cleanEnv strips KIDO_TMUX from
	// every environment this harness builds, including the servers' own, so
	// without this symlink the built kidoBin would fall through to "tmux" on
	// PATH instead - exercising a resolution step no install ever takes.
	if tmuxBin != "" {
		if err := os.Symlink(tmuxBin, filepath.Join(filepath.Dir(kidoBin), "kido-tmux")); err != nil {
			return 0, err
		}
		// share/tmux/kido-tmux.conf's C-s binding runs a literal "tmux", resolved
		// through the inner server's own PATH the way a production kido
		// pane resolves it through the share/bin/tmux shim - which a bare
		// go build here has no installed copy of. This directory stands in
		// for it, holding only the patched fork under that name so nothing
		// else on PATH is shadowed; only the popup test puts it on a
		// server's PATH.
		tmuxDir = filepath.Join(dir, "tmux-bin")
		if err := os.MkdirAll(tmuxDir, 0o755); err != nil {
			return 0, err
		}
		if err := os.Symlink(tmuxBin, filepath.Join(tmuxDir, "tmux")); err != nil {
			return 0, err
		}
		serverPathPrefix = filepath.Dir(kidoBin) + string(os.PathListSeparator) + tmuxDir
		if err := startWatchdog(); err != nil {
			return 0, err
		}
	}
	return m.Run(), nil
}

// installKido builds dune's install tree from the repository root and
// copies its bin and share into prefix, dereferenced, so kido's own
// lookups start from prefix rather than from _build. DUNE_BUILD_DIR is
// dune's own, which scripts/ci-like points outside the bind-mounted
// checkout.
func installKido(prefix string) error {
	build := exec.Command("dune", "build", "@install")
	build.Dir = ".."
	if b, err := build.CombinedOutput(); err != nil {
		return fmt.Errorf("dune build @install: %v\n%s", err, b)
	}
	tree := filepath.Join(cmp.Or(os.Getenv("DUNE_BUILD_DIR"), "_build"), "install", "default")
	if !filepath.IsAbs(tree) {
		tree = filepath.Join("..", tree)
	}
	cp := exec.Command("cp", "-RL", filepath.Join(tree, "bin"), filepath.Join(tree, "share"), prefix)
	if b, err := cp.CombinedOutput(); err != nil {
		return fmt.Errorf("copy the install tree: %v\n%s", err, b)
	}
	stamped := exec.Command("cp", "-f", "../build/main.exe", filepath.Join(prefix, "bin", "kido"))
	if b, err := stamped.CombinedOutput(); err != nil {
		return fmt.Errorf("copy the promoted binary: %v\n%s", err, b)
	}
	return nil
}

// buildFakeAgent compiles a binary named name that sleeps (copying
// /bin/sleep fails code signing on macOS) and echoes every stdin line it
// reads, so a test can drive a claudePane with send-keys and read back
// what arrived. Two lines are commands instead: "busy" and "esc" redraw
// the pane as real Claude Code would, since kido reads a waiting pane's
// screen to notice a dismissed prompt (lib/screen.ml).
func buildFakeAgent(srcRoot, outDir, name string) (string, error) {
	src := filepath.Join(srcRoot, "fakeagent-"+name)
	if err := os.MkdirAll(src, 0o755); err != nil {
		return "", err
	}
	main := `package main

import (
	"bufio"
	"fmt"
	"os"
	"time"
)

const rule = "────────────────────────────────────────"

func box(footer string) {
	fmt.Printf("\n%s\n❯ \n%s\n  %s\n", rule, rule, footer)
}

func main() {
	fmt.Print("\nDo you prefer tea or coffee?\n\n❯ 1. Tea\n  2. Coffee\n\n" +
		"Enter to select · Esc to cancel\n")
	sc := bufio.NewScanner(os.Stdin)
	for sc.Scan() {
		switch sc.Text() {
		case "busy":
			box("⏸ manual mode on · esc to interrupt · ← for agents")
		case "esc":
			box("⏸ manual mode on · ? for shortcuts · ← for agents")
		default:
			fmt.Println("got:", sc.Text())
		}
	}
	time.Sleep(30 * time.Minute)
}
`
	if err := os.WriteFile(filepath.Join(src, "main.go"), []byte(main), 0o644); err != nil {
		return "", err
	}
	out := filepath.Join(outDir, name) // no go.mod needed: stdlib only
	cmd := exec.Command("go", "build", "-o", out, "main.go")
	cmd.Dir = src
	if b, err := cmd.CombinedOutput(); err != nil {
		return "", fmt.Errorf("go build fake agent %s: %v\n%s", name, err, b)
	}
	return out, nil
}

// cleanEnv strips KIDO_TMUX, so kido must resolve the tmux binary on its
// own rather than through the harness's, and every KIDO_AGENT_*, so a
// test run from inside a tracked agent's pane does not leak that parent
// edge into everything the harness spawns (including the inner server,
// whose own environment is what new-window hands a spawned child).
func cleanEnv(extra ...string) []string {
	env := make([]string, 0, len(os.Environ())+len(extra))
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "KIDO_TMUX=") && !strings.HasPrefix(kv, "KIDO_AGENT_") && !strings.HasPrefix(kv, "TMUX=") && !strings.HasPrefix(kv, "TMUX_PANE=") {
			env = append(env, kv)
		}
	}
	env = append(env, extra...)
	for i, kv := range env {
		if strings.HasPrefix(kv, "PATH=") {
			paths := []string{}
			for _, path := range filepath.SplitList(strings.TrimPrefix(kv, "PATH=")) {
				if !strings.HasSuffix(strings.TrimRight(path, "/"), "share/kido/bin") {
					paths = append(paths, path)
				}
			}
			env[i] = "PATH=" + strings.Join(paths, string(os.PathListSeparator))
		}
	}
	return env
}

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
// sidebar has rendered it. Extra arguments are passed to kido: a long
// --interval makes a test prove that an update came from tmux's control-mode
// notifications rather than from the next poll.
func start(t *testing.T, session string, kidoArgs ...string) *harness {
	t.Helper()
	return startPathPrefix(t, session, "", kidoArgs...)
}

// startPathPrefix is start with pathDir ahead of the inner server's PATH,
// which always carries serverPathPrefix (the built kido and the patched
// tmux) regardless of pathDir. The server's own environment is the only
// place either works: tmux looks a pane's command up in the environment
// of the server process, not in the session environment it hands the
// child, so `set-environment PATH` on a running server does not find it.
//
// It is a whole harness's PATH, so a fake put there shadows that name for
// every pane of that test - including the shells the test types into,
// whose startup files run commands of their own. Pass a directory holding
// only the name being faked.
func startPathPrefix(t *testing.T, session, pathDir string, kidoArgs ...string) *harness {
	t.Helper()
	requireTmux(t)

	h := &harness{t: t, dir: t.TempDir()}
	// The socket names must not collide with a server another run left
	// behind, so they carry the pid and a random tag.
	name := fmt.Sprintf("%s-%d-%d", sanitize.ReplaceAllString(t.Name(), "-"),
		os.Getpid(), rand.Int32N(1<<20))
	h.outer = "kido-o-" + name
	h.inner = "kido-i-" + name
	// Registered before either server exists: a server this process has
	// asked for but not yet seen must still die with it.
	watchSockets(h.outer, h.inner)
	h.stateDir = filepath.Join(h.dir, "state")
	if err := os.MkdirAll(h.stateDir, 0o755); err != nil {
		t.Fatal(err)
	}

	args := ""
	if len(kidoArgs) > 0 {
		args = " " + strings.Join(kidoArgs, " ")
	}
	conf := filepath.Join(h.dir, "inner.conf")
	// KIDO_STATE_DIR is set in the inner server's global environment before
	// any session exists, so every pane and the side-status-command job
	// itself inherit it rather than touching the developer's real state
	// dir; h.hook and h.agentStatus set their own copies out of band.
	// KIDO_LINGER_SECONDS/KIDO_STALL_THRESHOLD_MS/KIDO_STREAM_* shorten the
	// window-lifecycle grace, State.stall_threshold and the streaming
	// wrapper's batch/backoff the same way for everything the inner server
	// runs, so real production values (30s, 3min, 250ms) don't put every
	// timing test past the 5s settle; global per server, so 3s (not
	// shorter) leaves room for tests that sleep up to a second before
	// checking a status is still shown running.
	// The shipped defaults are written first, byte for byte
	// (share/tmux/kido-tmux.conf, as a real launch does),
	// then the harness's own overrides.
	prefix := serverPathPrefix
	if pathDir != "" {
		prefix = pathDir + string(os.PathListSeparator) + prefix
	}
	defaults, err := os.ReadFile("../share/tmux/kido-tmux.conf")
	if err != nil {
		t.Fatal(err)
	}
	var body bytes.Buffer
	body.Write(defaults)
	fmt.Fprintf(&body, `
set-environment -g KIDO_STATE_DIR "%s"
set-environment -g KIDO_LINGER_SECONDS 1
set-environment -g KIDO_CAFFEINATE_GRACE_MS 2000
set-environment -g KIDO_STOP_ESCALATION_MS 300
set-environment -g KIDO_STALL_THRESHOLD_MS 3000
set-environment -g KIDO_STREAM_BATCH_MS 100
set-environment -g KIDO_STREAM_BACKOFF_MS 100
set-environment -g KIDO_STREAM_BACKOFF_CAP_MS 500
set -g status off
set -sg escape-time 0
set -g default-shell /bin/bash
set -g default-command ""
set -g side-status-width %d
set -g side-status-style "fg=default,bg=default"
set -g side-status-command "%s%s"
`, h.stateDir, sideWidth, kidoBin, args)
	if err := os.WriteFile(conf, body.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}

	t.Cleanup(func() {
		// Asked of the inner server itself, not a machine-wide process scan,
		// which could not distinguish this server's control client from one
		// belonging to some other tmux server started during the test.
		pids := controlClientPIDs(h.inner)
		// More than one is a real bug: Tmux.Conn kills the old child
		// before dialling a new one (lib_tmux/conn.ml).
		if len(pids) > 1 {
			t.Errorf("more than one control client attached to %s: %v", h.inner, pids)
		}
		started := descendants(socketPath("", h.inner))
		killServer(h.inner)
		killServer(h.outer)
		for _, pid := range pids {
			if !processGone(pid, time.Second) {
				t.Errorf("leaked control client pid %s for socket %s", pid, h.inner)
			}
		}
		// An async-run wrapper answers the server's hangup by writing its
		// outcome into the state dir, after kill-server has returned; TempDir's
		// removal runs next and must not race it.
		waitDescendantsGone(t, h.inner, started)
	})

	h.must(h.tmux(h.outer, "-f", "/dev/null", "new-session", "-d", "-s", "host",
		"-x", strconv.Itoa(outerCols), "-y", strconv.Itoa(outerRows)))
	// screen-256color: the only terminfo CI's Ubuntu (no ncurses-term) has.
	h.must(h.tmux(h.outer, "set-option", "-g", "default-terminal", "screen-256color"))
	h.must(h.tmux(h.outer, "set-option", "-g", "remain-on-exit", "on")) // keep a dead client's error on screen
	inner := fmt.Sprintf("PATH=%q:$PATH; export PATH; unset TMUX; exec %q -L %s -f %q new-session -s %s -c %q",
		prefix, tmuxBin, h.inner, conf, session, h.dir)
	h.must(h.tmux(h.outer, "new-window", "-d", "-t", "host", "-n", "side", inner))

	h.waitFor(func() bool { return hasLine(h.sidebar(), session) }, settle,
		msgf("sidebar shows session %s", session))
	h.client = strings.TrimSpace(strings.Split(h.in("list-clients", "-F", "#{client_name}"), "\n")[0])
	return h
}

// controlClientPIDs asks a tmux server for the pids of its own
// control-mode clients (kido's connection, and nothing else): the server
// is authoritative about its own clients, unlike a process-table scan
// that cannot tell this test's control client from anyone else's. It
// returns nothing once the server is gone, which is why callers must ask
// before killing it.
func controlClientPIDs(socket string) []string {
	out, err := exec.Command(tmuxBin, "-L", socket, "list-clients", "-F",
		"#{client_pid}\t#{client_control_mode}").Output()
	if err != nil {
		return nil
	}
	var pids []string
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if pid, mode, ok := strings.Cut(line, "\t"); ok && mode == "1" {
			pids = append(pids, pid)
		}
	}
	return pids
}

type process struct{ pid, command string }

func waitDescendantsGone(t *testing.T, socket string, started []process) {
	t.Helper()
	deadline := time.Now().Add(settle)
	for _, p := range started {
		if !processGone(p.pid, time.Until(deadline)) {
			t.Errorf("pid %s (%s), started under %s, outlived its server by %v", p.pid, p.command, socket, settle)
		}
	}
}

// descendants lists every process below a tmux server: its panes' and its
// jobs' and theirs, including a killed pane's that has not exited yet.
// Asked before the server is killed, after which they are init's.
func descendants(socket string) []process {
	root, err := exec.Command(tmuxBin, "-S", socket, "display-message", "-p", "#{pid}").Output()
	if err != nil {
		return nil
	}
	table, err := exec.Command("ps", "-A", "-o", "pid=,ppid=,command=").Output()
	if err != nil {
		return nil
	}
	children := map[string][]process{}
	for _, line := range strings.Split(string(table), "\n") {
		if f := strings.Fields(line); len(f) >= 3 {
			children[f[1]] = append(children[f[1]], process{f[0], strings.Join(f[2:], " ")})
		}
	}
	var all []process
	for queue := children[strings.TrimSpace(string(root))]; len(queue) > 0; queue = queue[1:] {
		all = append(all, queue[0])
		queue = append(queue, children[queue[0].pid]...)
	}
	return all
}

// processGone polls for pid to exit within budget. kido holds the only
// write end of its control client's stdin, so the pipe closes and the
// client exits on its own the moment kido dies - by kill-server's own
// SIGTERM to the side-status job, or otherwise - without kido needing a
// signal handler; this is a regression guard on that staying true, not
// a check that can currently fail on its own.
func processGone(pid string, budget time.Duration) bool {
	deadline := time.Now().Add(budget)
	for {
		if exec.Command("kill", "-0", pid).Run() != nil {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// killServer stops a test server and unlinks its socket, which tmux
// sometimes leaves behind in the shared socket directory.
//
// It addresses the server by path, like the watchdog and for the same
// reason: a socket *name* is resolved against a list of directories and
// silently falls through to /tmp when the first of them cannot be
// resolved, so a name is a request to kill whatever server answers to it
// anywhere, rather than the one this test started.
func killServer(socket string) {
	path := socketPath("", socket)
	exec.Command(tmuxBin, "-S", path, "kill-server").Run()
	os.Remove(path)
}

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

func (h *harness) in(args ...string) string {
	h.t.Helper()
	return h.must(h.tmux(h.inner, args...))
}

// startCommand reads windowID's #{pane_start_command}: tmux's own record
// of the argv it was handed, past kido's command-line construction and
// tmux's parsers, which is a better witness than what the spawned
// process itself reports it was given.
func (h *harness) startCommand(windowID string) string {
	h.t.Helper()
	return h.in("display-message", "-p", "-t", windowID, "#{pane_start_command}")
}

func (h *harness) out(args ...string) string {
	h.t.Helper()
	return h.must(h.tmux(h.outer, args...))
}

// sendKeys sends one send-keys call per key: tmux drops keys batched
// with the prefix.
func (h *harness) sendKeys(keys ...string) {
	h.t.Helper()
	for _, k := range keys {
		h.out("send-keys", "-t", "host:side", k)
		time.Sleep(60 * time.Millisecond)
	}
}

func (h *harness) sendLiteral(s string) {
	h.t.Helper()
	h.out("send-keys", "-t", "host:side", "-l", s)
	time.Sleep(60 * time.Millisecond)
}

func (h *harness) prefix(key string) {
	h.t.Helper()
	h.sendKeys("C-b")
	h.sendKeys(key)
}

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

// reverseRE matches an SGR escape that turns on reverse video (parameter
// 7), tolerating tmux combining it with other attributes in the same
// escape ("\x1b[1;7m") rather than requiring a literal "\x1b[7m".
var reverseRE = regexp.MustCompile(`\x1b\[(?:\d+;)*7(?:;\d+)*m`)

// leadingEscRE matches a run of SGR escapes at the very start of a
// string, for stripping the ones a style change emits alongside a
// reverse-video toggle before the real text.
var leadingEscRE = regexp.MustCompile(`^(?:\x1b\[[0-9;]*m)+`)

// sgrOn holds, per SGR parameter the tests read, a matcher for an escape
// that turns that attribute on. Built once so it is safe to share between
// parallel tests.
var sgrOn = map[string]*regexp.Regexp{
	"7":  reverseRE,                                         // reverse video: the selected row
	"1":  regexp.MustCompile(`\x1b\[(?:\d+;)*1(?:;\d+)*m`),  // bold: the client's session
	"31": regexp.MustCompile(`\x1b\[(?:\d+;)*31(?:;\d+)*m`), // red: a failed command's indicator
	"32": regexp.MustCompile(`\x1b\[(?:\d+;)*32(?:;\d+)*m`), // green: a done indicator
}

// indField is the sidebar's indicator field as the tests spell it: the
// glyph alone, or a single space when there is none. It mirrors
// Ui.parts (lib/ui.ml).
func indField(glyph string) string {
	if glyph == "" {
		return " "
	}
	return glyph
}

func hasSGR(line, param string) bool {
	re, ok := sgrOn[param]
	if !ok {
		panic("hasSGR: no matcher for SGR parameter " + param)
	}
	return re.MatchString(line)
}

func (h *harness) capture() []string {
	h.t.Helper()
	out, err := h.tmux(h.outer, "capture-pane", "-p", "-e", "-t", "host:side")
	if err != nil {
		return nil
	}
	return strings.Split(out, "\n")
}

// sideOf cuts the side column out of a captured line, escape sequences
// and all; the separator rune cannot occur inside an escape, so cutting
// before stripping keeps the window area's attributes out of SGR checks.
func sideOf(line string) string {
	if i := strings.IndexRune(line, '│'); i >= 0 {
		return line[:i]
	}
	return line
}

func sideText(line string) string { return strings.TrimSpace(ansi.Strip(sideOf(line))) }

func sidebarOf(lines []string) []string {
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		out = append(out, sideText(line))
	}
	return out
}

func (h *harness) sidebar() []string { return sidebarOf(h.capture()) }

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

func (h *harness) sidebarVisible() bool { return h.separatorAt(sideWidth) }

func rowsOf(lines []string) []string {
	var out []string
	for _, l := range sidebarOf(lines) {
		if l != "" && !strings.HasPrefix(l, "☕") {
			out = append(out, l)
		}
	}
	return out
}

func (h *harness) rows() []string { return rowsOf(h.capture()) }

func selectedRowOf(lines []string) string {
	for _, line := range lines {
		if hasSGR(sideOf(line), "7") {
			return sideText(line)
		}
	}
	return ""
}

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

func (h *harness) waitSelectedLine(n int) {
	h.t.Helper()
	h.waitFor(func() bool { return h.selectedIndex() == n }, settle, func() string {
		lines := h.capture()
		return fmt.Sprintf("selection on line %d (is %d: %q)", n,
			selectedIndexOf(lines), selectedRowOf(lines))
	})
}

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

func rowIndexOf(lines []string, sub string) int {
	for i, l := range sidebarOf(lines) {
		if strings.Contains(l, sub) {
			return i + 1
		}
	}
	return 0
}

func (h *harness) rowIndex(sub string) int { return rowIndexOf(h.capture(), sub) }

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

// diagnose renders a compact snapshot of both servers for a failed waitFor.
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
	// h.in would fail the test from inside diagnose(); use h.tmux directly.
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

func (h *harness) waitRow(sub string) {
	h.t.Helper()
	h.waitFor(func() bool { return hasLine(h.sidebar(), sub) }, settle,
		msgf("row %q", sub))
}

func (h *harness) waitRows(n int) {
	h.t.Helper()
	h.waitFor(func() bool { return len(h.rows()) == n }, settle, func() string {
		return fmt.Sprintf("%d rows (are %q)", n, h.rows())
	})
}

func (h *harness) waitSelected(sub string) {
	h.t.Helper()
	h.waitFor(func() bool { return strings.Contains(h.selectedRow(), sub) }, settle,
		func() string { return fmt.Sprintf("selection on %q (is %q)", sub, h.selectedRow()) })
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
		msgf("client attached to %s", name))
}

func (h *harness) waitFocused(want bool) {
	h.t.Helper()
	h.waitFor(func() bool { return h.clientFocused() == want }, settle,
		msgf("side-status-focus = %v", want))
}

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

func (h *harness) waitPanePrompt(id string) {
	h.t.Helper()
	h.waitFor(func() bool {
		return reportedPrompt(h.in("display-message", "-p", "-t", id, "#{pane_last_prompt_time}"))
	}, settle, msgf("pane %s to report its first prompt", id))
}

// reportedPrompt reads #{pane_last_prompt_time}. A pane that has never
// reported one answers with the *empty string*, not "0": tmux formats an
// unset timestamp as empty (measured on the fork), so a check for "0"
// alone holds for every pane there has ever been.
func reportedPrompt(v string) bool { return v != "" && v != "0" }

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

// hook runs `kido hook` out of band from the test binary (whose pid it
// records, so the state file stays valid for the whole run), and so
// carries KIDO_STATE_DIR itself instead of inheriting it as a pane does.
func (h *harness) hook(sessionID, pane, event string, kv ...string) {
	h.t.Helper()
	payload := map[string]any{}
	for i := 0; i+1 < len(kv); i += 2 {
		payload[kv[i]] = kv[i+1]
	}
	h.hookPayload(sessionID, pane, event, payload)
}

// hookPayload is hook for a payload with non-string fields (e.g.
// background_tasks, a list of objects).
func (h *harness) hookPayload(sessionID, pane, event string, payload map[string]any) {
	h.t.Helper()
	payload["hook_event_name"] = event
	payload["session_id"] = sessionID
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

// agentStatus runs `kido agent-status`, the way a non-Claude-Code agent
// reports itself, out of band like hook.
func (h *harness) agentStatus(sessionID, pane, agent, status string, extra ...string) {
	h.t.Helper()
	args := []string{"agent-status", "--agent", agent, "--session", sessionID}
	if status != "" {
		args = append(args, "--status", status)
	}
	cmd := exec.Command(kidoBin, append(args, extra...)...)
	cmd.Env = cleanEnv("TMUX_PANE="+pane, "KIDO_STATE_DIR="+h.stateDir)
	if out, err := cmd.CombinedOutput(); err != nil {
		h.t.Fatalf("kido agent-status %s: %v\n%s", status, err, out)
	}
}

// agentWithInbox sets up a window that looks to kido exactly like a live
// pi session with an inbox: a real long-running pane, plus a state
// record (via agentStatus, so its pid is this test binary's own and
// stays alive) naming a real unix socket that answers "ok\n" to anything
// and otherwise does nothing.
func (h *harness) agentWithInbox(session, sessionID string) (*inbox, string) {
	h.t.Helper()
	paneID := h.newWindow(session, "", "sh", "-c", "exec sleep 300")
	h.waitPaneCommand(paneID, "sleep")
	in := startInbox(h.t, "ok\n")
	h.agentStatus(sessionID, paneID, "pi", "idle",
		"--inbox", in.Path)
	return in, paneID
}

// waitFileContains waits until path holds sub, then returns its whole
// contents. Every "run kido and read its output" helper here ends its
// script with an "rc=<code>" line: waiting for that (not waitFileNonEmpty)
// tells a finished command from one caught mid-write.
func (h *harness) waitFileContains(path, sub string) string {
	h.t.Helper()
	var content []byte
	h.waitFor(func() bool {
		b, err := os.ReadFile(path)
		if err != nil || !strings.Contains(string(b), sub) {
			return false
		}
		content = b
		return true
	}, settle, msgf("%s to contain %q", path, sub))
	return string(content)
}

// piPane opens a window in session running the fake agent named "node",
// which is what tmux reports for a real pi pane, and titles it the way pi
// titles its pane ("π - <session> - <cwd>"). The pane is nothing to kido
// until pi reports through agentStatus.
func (h *harness) piPane(session, title string) string {
	h.t.Helper()
	id := h.newWindow(session, "", nodeBin, "--")
	h.waitPaneCommand(id, "node")
	h.title(id, title)
	return id
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

// fakeClaude sends one of the fake claude's screen commands to pane:
// "busy" for the input box with work in flight, "esc" for the input box
// with nothing running (what a dismissed prompt leaves behind).
func (h *harness) fakeClaude(pane, cmd string) {
	h.t.Helper()
	h.in("send-keys", "-t", pane, "-l", cmd)
	h.in("send-keys", "-t", pane, "Enter")
}

// title names a pane the way an agent does ("✳ <name>", "π - <name>"). A shell in the
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
