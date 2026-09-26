package e2e

import (
	"bytes"
	"fmt"
	"math/rand/v2"
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
// own live kido server on 2026-09-26; TestWatchdogWithAVanishedTmpdir-
// KillsNothingElse is the test. A -S path is taken literally and
// resolves against nothing, and a socket that is gone is skipped rather
// than looked for anywhere else.
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
func socketPath(tmpdir, name string) string {
	if tmpdir == "" {
		tmpdir = os.Getenv("TMUX_TMPDIR")
	}
	if tmpdir == "" {
		tmpdir = "/tmp"
	}
	if resolved, err := filepath.EvalSymlinks(tmpdir); err == nil {
		tmpdir = resolved
	}
	return filepath.Join(tmpdir, fmt.Sprintf("tmux-%d", os.Getuid()), name)
}

// fallbackSocketPath is where a socket *name* resolves once every
// earlier entry of tmux's socket path list has failed. TMUX_SOCK is
// "$TMUX_TMPDIR:" _PATH_TMP, so /tmp is the last resort whatever
// TMUX_TMPDIR says - which is why a deleted TMUX_TMPDIR does not fail,
// it lands in /tmp. The live server the watchdog killed was there, and
// that makes /tmp the only place a witness for this bug can stand.
func fallbackSocketPath(name string) string {
	return socketPath("/tmp", name)
}

// startWatchdog is called once, from setup(), after tmuxBin is known.
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
		watchSocketIn("", n)
	}
}

// watchSocketIn is watchSockets for a server with a TMUX_TMPDIR of its
// own. The path is worked out now, while that directory is still there,
// because the watchdog runs after the test has deleted it.
func watchSocketIn(tmpdir, name string) {
	watchSocketPath(socketPath(tmpdir, name))
}

// watchSocketPath registers a socket the caller has already resolved.
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

// TestServersDieWithTheTestProcess is the regression test for a test
// binary that ended without running its cleanups and left both of a
// harness's tmux servers behind. Measured on 2026-09-26: an agent's bash
// tool killed a `go test ./e2e/` process group at its 120s timeout, and
// the two servers of TestSecondHolderOfASessionIdIsRefused were still up
// thirteen hours later - the inner one restarting its side-status-command
// once a second against a kido binary in a deleted temp directory, some
// fifty thousand ptys in, until an openpty spun in the kernel.
//
// It kills a process group, because that is what happened and because it
// is the hardest case: a watchdog left in the test's own group dies with
// it. The child is a real `go test` running the harness, not a hand-rolled
// pair of servers, so what the test exercises is the harness every other
// test in this package starts.
func TestServersDieWithTheTestProcess(t *testing.T) {
	requireTmux(t)
	if os.Getenv(childSocketsEnv) != "" {
		t.Skip("this is the child process")
	}

	sockFile := filepath.Join(t.TempDir(), "sockets")
	child := exec.Command("go", "test", ".", "-count=1", "-timeout", "120s",
		"-run", "TestWatchdogChildHangsWithAHarnessUp")
	child.Env = append(cleanEnv(),
		childSocketsEnv+"="+sockFile,
		"KIDO_E2E_REQUIRED=1",
		"KIDO_TMUX="+tmuxBin)
	// Its own process group, so the SIGKILL below reaches the whole child
	// run - `go test`, the test binary it spawns, and anything still in
	// their group - the way the bash tool's timeout did.
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

// TestWatchdogChildHangsWithAHarnessUp is the child half: it brings up a
// harness, says where its servers are and then never finishes, so nothing
// it registered with t.Cleanup ever runs. It skips unless its parent
// pointed childSocketsEnv at a file.
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

// serverUp reports whether a tmux server is running on this socket.
// display-message is a command that never starts one.
func serverUp(socket string) bool {
	return exec.Command(tmuxBin, "-L", socket, "display-message", "-p", "up").Run() == nil
}

// serverUpAt is serverUp for a socket named by its full path.
func serverUpAt(path string) bool {
	return exec.Command(tmuxBin, "-S", path, "display-message", "-p", "up").Run() == nil
}

// childVictimEnv carries "<directory to delete>\x1f<socket name>" to the
// child half of TestWatchdogWithAVanishedTmpdirKillsNothingElse, and its
// presence is what makes that child test run at all.
const childVictimEnv = "KIDO_E2E_WATCHDOG_CHILD_VICTIM"

// TestWatchdogWithAVanishedTmpdirKillsNothingElse is the regression test
// for the watchdog killing the developer's own live kido server, on
// 2026-09-26. The launcher tests register a server called "kido" under a
// TMUX_TMPDIR of their own and their cleanup deletes that directory, so
// by the time the watchdog fired it was addressing a socket by *name*
// with TMUX_TMPDIR naming a directory that was gone. A name is resolved
// against a path list - TMUX_SOCK is "$TMUX_TMPDIR:" _PATH_TMP
// (third_party/tmux/tmux.h) and expand_paths drops any entry whose
// realpath fails (tmux.c) - so the deleted directory fell out of the
// list and the name resolved in /tmp, where the live server of that name
// was. A path given with -S is taken literally and resolves against
// nothing.
//
// The witness stands exactly where such a fallthrough lands: the same
// socket name, in this process's own default socket directory. It is a
// server this test starts itself, addressed by path, under a name unique
// to this run - so nothing but this bug can be what kills it.
func TestWatchdogWithAVanishedTmpdirKillsNothingElse(t *testing.T) {
	requireTmux(t)
	if os.Getenv(childVictimEnv) != "" {
		t.Skip("this is the child process")
	}

	// Unique, and so never the "kido" of a real server: the only socket
	// this test can reach in the shared fallback directory is its own.
	name := fmt.Sprintf("kido-witness-%d-%d", os.Getpid(), rand.Int32N(1<<20))
	witness := fallbackSocketPath(name)
	watchSocketPath(witness)
	if err := os.MkdirAll(filepath.Dir(witness), 0o700); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command(tmuxBin, "-S", witness, "-f", "/dev/null",
		"new-session", "-d", "-s", "w").CombinedOutput(); err != nil {
		t.Fatalf("start witness server: %v: %s", err, out)
	}
	t.Cleanup(func() {
		exec.Command(tmuxBin, "-S", witness, "kill-server").Run()
		os.Remove(witness)
	})
	if !serverUpAt(witness) {
		t.Fatalf("witness server %s did not start", witness)
	}

	// The victim: a directory shaped like a launcher test's, deleted
	// before the child dies exactly as that test's cleanup deletes it.
	victimDir, err := os.MkdirTemp("", "kido-victim")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(victimDir)

	child := exec.Command("go", "test", ".", "-count=1", "-timeout", "120s",
		"-run", "TestWatchdogChildRegistersAVanishingTmpdir")
	child.Env = append(cleanEnv(),
		childVictimEnv+"="+victimDir+"\x1f"+name,
		"KIDO_E2E_REQUIRED=1",
		"KIDO_TMUX="+tmuxBin)
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

	deadline := time.Now().Add(90 * time.Second)
	for {
		if _, err := os.Stat(filepath.Join(victimDir, "registered")); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("child never registered its victim:\n%s", out.String())
		}
		time.Sleep(200 * time.Millisecond)
	}
	if err := os.RemoveAll(victimDir); err != nil {
		t.Fatal(err)
	}

	if err := syscall.Kill(-group, syscall.SIGKILL); err != nil {
		t.Fatal(err)
	}
	killed = true
	child.Wait()

	// The watchdog fires the moment the pipe closes, so a witness still
	// up across this span is one it never reached rather than one it has
	// not reached yet.
	for i := 0; i < 50; i++ {
		if !serverUpAt(witness) {
			t.Fatalf("the watchdog killed %s, a server it was never given: "+
				"a registered socket whose TMUX_TMPDIR had been deleted "+
				"resolved into the default socket directory", witness)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// TestWatchdogChildRegistersAVanishingTmpdir is the child half: it
// registers a server in a directory that is about to be deleted, and
// hangs, so nothing it registered with t.Cleanup ever runs.
func TestWatchdogChildRegistersAVanishingTmpdir(t *testing.T) {
	spec := os.Getenv(childVictimEnv)
	if spec == "" {
		t.Skip("run only by TestWatchdogWithAVanishedTmpdirKillsNothingElse")
	}
	requireTmux(t)
	dir, name, _ := strings.Cut(spec, "\x1f")
	watchSocketIn(dir, name)
	if err := os.WriteFile(filepath.Join(dir, "registered"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	time.Sleep(110 * time.Second) // the parent's SIGKILL lands long before this
}
