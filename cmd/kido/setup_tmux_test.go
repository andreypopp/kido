package main

import (
	"fmt"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestTmuxConfBlockShape checks the guard is well-formed without a tmux:
// one `if-shell` naming the path twice, once in the test and once in the
// source-file it guards, between the markers.
func TestTmuxConfBlockShape(t *testing.T) {
	const path = "/opt/homebrew/share/kido/kido-side.tmux"
	block, err := tmuxConfBlock(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(block, tmuxConfBegin+"\n") || !strings.HasSuffix(block, tmuxConfEnd+"\n") {
		t.Fatalf("block is not wrapped in its markers:\n%s", block)
	}
	body := strings.TrimSuffix(strings.TrimPrefix(block, tmuxConfBegin+"\n"), tmuxConfEnd+"\n")
	// The continuation is what keeps it one command over two lines.
	joined := strings.ReplaceAll(body, "\\\n", " ")
	if strings.Count(joined, "\n") != 1 {
		t.Errorf("body is not one command:\n%s", body)
	}
	for _, want := range []string{
		`if-shell '[ -f "` + path + `" ]'`,
		`'source-file "` + path + `"'`,
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("body does not contain %q:\n%s", want, body)
		}
	}
}

// A path kido cannot quote into tmux.conf is refused rather than written
// as a line tmux would misparse.
func TestTmuxConfBlockRefusesUnquotablePaths(t *testing.T) {
	for _, path := range []string{
		"/home/it's mine/kido-side.tmux",
		`/home/u/"q"/kido-side.tmux`,
		"/home/u/$HOME/kido-side.tmux",
		"/home/u/#1/kido-side.tmux",
		`/home/u/back\slash/kido-side.tmux`,
	} {
		if _, err := tmuxConfBlock(path); err == nil {
			t.Errorf("tmuxConfBlock(%q) = nil error, want one", path)
		}
	}
	// A space is the case that actually happens, and is quoted, not
	// refused.
	if _, err := tmuxConfBlock("/Users/u/Application Support/kido-side.tmux"); err != nil {
		t.Errorf("tmuxConfBlock with a space = %v, want it quoted", err)
	}
}

// TestTmuxConfBlockParses runs the generated block through a real tmux:
// the guard has to be a command tmux accepts, it has to source the file
// when it is there, and it has to stay quiet when it is not. Any tmux
// parses if-shell and source-file, so the patched fork is not needed;
// without one the test skips. Exit codes are no use here (tmux swallows
// config errors), so the sourced file sets an option and the test reads it
// back.
func TestTmuxConfBlockParses(t *testing.T) {
	bin := os.Getenv("KIDO_TMUX")
	if bin == "" {
		bin = "tmux"
	}
	tmux, err := exec.LookPath(bin)
	if err != nil {
		t.Skipf("no tmux to test against: %v", err)
	}

	sourced := func(t *testing.T, source string) string {
		t.Helper()
		dir := t.TempDir()
		conf := filepath.Join(dir, "tmux.conf")
		block, err := tmuxConfBlock(source)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(conf, []byte(block), 0o644); err != nil {
			t.Fatal(err)
		}
		socket := fmt.Sprintf("kido-test-%d", rand.Uint32())
		run := func(args ...string) (string, error) {
			cmd := exec.Command(tmux, append([]string{"-L", socket, "-f", conf}, args...)...)
			// A server must not try to nest inside the tmux the tests
			// may themselves be running in.
			cmd.Env = append(os.Environ(), "TMUX=")
			out, err := cmd.CombinedOutput()
			return strings.TrimSpace(string(out)), err
		}
		if out, err := run("new-session", "-d", "-x", "80", "-y", "24"); err != nil {
			t.Fatalf("tmux new-session: %v (%s)", err, out)
		}
		t.Cleanup(func() { run("kill-server") }) //nolint:errcheck // best effort
		out, err := run("show-options", "-gqv", "@kido-sourced")
		if err != nil {
			t.Fatalf("tmux show-options: %v (%s)", err, out)
		}
		return out
	}

	dir := t.TempDir()
	side := filepath.Join(dir, "kido-side.tmux")
	if err := os.WriteFile(side, []byte("set -g @kido-sourced yes\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := sourced(t, side); got != "yes" {
		t.Errorf("@kido-sourced = %q, want the config to have been sourced", got)
	}
	// The guard's whole point: a missing file leaves a working server.
	if got := sourced(t, filepath.Join(dir, "gone.tmux")); got != "" {
		t.Errorf("@kido-sourced = %q, want nothing sourced", got)
	}
}
