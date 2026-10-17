package e2e

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// A test's tmux servers are daemons: they are in a session of their own,
// nothing this process holds keeps them alive, and the only thing that
// stops them is a kill-server in t.Cleanup. A test binary that ends
// without running its cleanups - a -timeout panic, a SIGKILL, an agent's
// bash tool killing the process group - therefore leaves them running
// forever, and an inner server whose side-status-command has gone with
// the temp directory it was built in restarts that command once a second
// for as long as it lives.
//
// So one sh process is started outside this process's group, holding the
// read end of a pipe as its stdin. Only this process holds the write end
// (Go opens every file descriptor close-on-exec, so nothing it spawns
// inherits it), which makes the pipe reach EOF exactly when this process
// dies, however it dies - and there is no way to exit that keeps a pipe
// open. The watchdog then kills every server it was told about. Being in
// a process group of its own is what saves it from the group kill, and
// ignoring the terminal signals is what saves it from the rest.
//
// Each line it reads is one socket's full path, and it kills by path
// with -S. Never by name with -L: a name is resolved against the path
// list TMUX_SOCK, "$TMUX_TMPDIR:" _PATH_TMP, whose entries expand_paths
// drops when their realpath fails (third_party/tmux tmux.h, tmux.c) - so
// a name registered under a TMUX_TMPDIR that has since been deleted does
// not fail to resolve, it resolves in /tmp instead, against whatever
// server of that name happens to be there. That killed the developer's
// own live kido server. A -S path is taken literally and resolves against
// nothing, and a socket that is gone is skipped rather than looked for
// anywhere else.
const watchdogScript = `
trap '' HUP INT TERM
tmux=$1
list=$(mktemp) || exit 1
while IFS= read -r sock; do
	printf '%s\n' "$sock" >>"$list"
done
while IFS= read -r sock; do
	[ -S "$sock" ] || continue
	"$tmux" -S "$sock" kill-server >/dev/null 2>&1
	rm -f "$sock"
done <"$list"
rm -f "$list"
`

var (
	watchdogMu sync.Mutex
	watchdogW  *os.File // the pipe whose EOF sets the watchdog going
)

// socketPath is where tmux puts the socket called name for a server
// started with this TMUX_TMPDIR - empty meaning this process's own, and
// /tmp when that is unset too, which is tmux's own default (_PATH_TMP).
// The directory is resolved here, while it still exists, because that is
// what tmux does with it and a path that resolves to nothing later must
// stay wrong rather than become something else.
func socketPath(name string) string {
	if filepath.IsAbs(name) {
		return name
	}
	tmpdir := os.Getenv("TMUX_TMPDIR")
	if tmpdir == "" {
		tmpdir = "/tmp"
	}
	if resolved, err := filepath.EvalSymlinks(tmpdir); err == nil {
		tmpdir = resolved
	}
	return filepath.Join(tmpdir, fmt.Sprintf("tmux-%d", os.Getuid()), name)
}

func startWatchdog() error {
	r, w, err := os.Pipe()
	if err != nil {
		return err
	}
	defer r.Close()
	cmd := exec.Command("/bin/sh", "-c", watchdogScript, "kido-e2e-watchdog", tmuxBin)
	cmd.Stdin = r
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		w.Close()
		return fmt.Errorf("start watchdog: %w", err)
	}
	watchdogW = w
	return nil
}

// watchSockets hands the watchdog servers named under this process's own
// TMUX_TMPDIR. Callers register before starting a server, not after: a
// server asked for and not yet seen must die with this process too.
func watchSockets(names ...string) {
	for _, n := range names {
		watchSocketPath(socketPath(n))
	}
}

func watchSocketPath(path string) {
	watchdogMu.Lock()
	defer watchdogMu.Unlock()
	if watchdogW == nil {
		return
	}
	fmt.Fprintln(watchdogW, path)
}

// childSocketsEnv names the file the child half of
// TestServersDieWithTheTestProcess writes its two socket names into. Its
// presence is also what tells the child test to run at all: an ordinary
// run of the suite skips it.
const childSocketsEnv = "KIDO_E2E_WATCHDOG_CHILD_SOCKETS"

// Regression test for a test binary that ended without running its
// cleanups and left both of a harness's tmux servers behind. Measured on
// 2026-09-26: an agent's bash tool killed a `go test ./test_e2e/` process
// group at its 120s timeout, and the two servers were still up thirteen
// hours later, the inner one restarting its side-status-command once a
// second against a kido binary in a deleted temp directory.
//
// Kills a process group, the hardest case: a watchdog left in the test's
// own group must die with it. The child is a real `go test` running the
// harness, not a hand-rolled pair of servers.
func TestServersDieWithTheTestProcess(t *testing.T) {
	requireTmux(t)
	t.Parallel()
	if os.Getenv(childSocketsEnv) != "" {
		t.Skip("this is the child process")
	}

	sockFile := filepath.Join(t.TempDir(), "sockets")
	child := exec.Command("go", "test", ".", "-count=1", "-timeout", "120s",
		"-run", "TestWatchdogChildHangsWithAHarnessUp")
	child.Env = append(cleanEnv(),
		childSocketsEnv+"="+sockFile,
		childPrefixEnv+"="+e2ePrefix,
		"KIDO_E2E_REQUIRED=1",
		"KIDO_TMUX="+tmuxBin)
	// Its own process group, so the SIGKILL below reaches `go test`, the
	// test binary it spawns, and anything still in their group.
	child.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	var out bytes.Buffer
	child.Stdout, child.Stderr = &out, &out
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	group := child.Process.Pid
	killed := false
	defer func() {
		if !killed {
			syscall.Kill(-group, syscall.SIGKILL)
			child.Wait()
		}
	}()

	var outer, inner string
	deadline := time.Now().Add(90 * time.Second)
	for {
		b, err := os.ReadFile(sockFile)
		if err == nil {
			if f := strings.Fields(string(b)); len(f) == 2 {
				outer, inner = f[0], f[1]
				break
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("child never reported its sockets:\n%s", out.String())
		}
		time.Sleep(200 * time.Millisecond)
	}
	for _, s := range []string{outer, inner} {
		if !serverUp(s) {
			t.Fatalf("server %s is not up before the kill:\n%s", s, out.String())
		}
	}

	if err := syscall.Kill(-group, syscall.SIGKILL); err != nil {
		t.Fatal(err)
	}
	killed = true
	child.Wait()

	deadline = time.Now().Add(20 * time.Second)
	for {
		up := []string{}
		for _, s := range []string{outer, inner} {
			if serverUp(s) {
				up = append(up, s)
			}
		}
		if len(up) == 0 {
			return
		}
		if time.Now().After(deadline) {
			for _, s := range up {
				killServer(s)
			}
			t.Fatalf("servers outlived the killed test process: %v", up)
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func TestWatchdogChildHangsWithAHarnessUp(t *testing.T) {
	path := os.Getenv(childSocketsEnv)
	if path == "" {
		t.Skip("run only by TestServersDieWithTheTestProcess")
	}
	requireTmux(t)
	h := start(t, "watchdog-child")
	// Written whole then renamed: the parent polls this file and must
	// never read half of it.
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(h.outer+"\n"+h.inner+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(tmp, path); err != nil {
		t.Fatal(err)
	}
	time.Sleep(110 * time.Second) // the parent's SIGKILL lands long before this
}

// serverUp: display-message is a command that never starts a server.
func serverUp(socket string) bool {
	return exec.Command(tmuxBin, "-S", socketPath(socket), "display-message", "-p", "up").Run() == nil
}
