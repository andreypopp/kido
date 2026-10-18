package e2e

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func serverDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "server-dir-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

func TestServerDirectorySafety(t *testing.T) {
	t.Parallel()
	requireTmux(t)
	for _, perm := range []os.FileMode{0o770, 0o750, 0o701} {
		dir := serverDir(t)
		if err := os.Chmod(dir, perm); err != nil {
			t.Fatal(err)
		}
		for _, args := range [][]string{
			{"server", "--server", dir},
			{"--server", dir},
			{"rpc", "--server", dir, "--client", "missing"},
			{"switch-window", "next", "--server", dir, "--client", "missing"},
			{"switch-session", "next", "--server", dir, "--client", "missing"},
		} {
			cmd := exec.Command(kidoBin, args...)
			cmd.Env = launcherEnv(t)
			out, err := cmd.CombinedOutput()
			if err == nil || !strings.Contains(string(out), "unsafe server directory") || !strings.Contains(string(out), dir) {
				t.Errorf("mode %o, %v: %v: %s", perm, args, err, out)
			}
		}
		if _, err := os.Stat(filepath.Join(dir, "socket")); !os.IsNotExist(err) {
			t.Fatalf("unsafe server created a socket: %v", err)
		}
	}
}

func TestServerDirectoryComma(t *testing.T) {
	t.Parallel()
	requireTmux(t)
	dir := filepath.Join(serverDir(t), "kido,work")
	for _, args := range [][]string{
		{"server", "--server", dir},
		{"--server", dir},
		{"rpc", "--server", dir, "--client", "missing"},
		{"switch-window", "next", "--server", dir, "--client", "missing"},
		{"switch-session", "next", "--server", dir, "--client", "missing"},
	} {
		cmd := exec.Command(kidoBin, args...)
		cmd.Env = launcherEnv(t)
		out, err := cmd.CombinedOutput()
		if err == nil || !strings.Contains(string(out), "must not contain a comma") || !strings.Contains(string(out), dir) {
			t.Errorf("%v: %v: %s", args, err, out)
		}
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatalf("comma path created a directory: %v", err)
	}
}

func TestServerSocketPathTooLong(t *testing.T) {
	t.Parallel()
	requireTmux(t)
	dir := filepath.Join(serverDir(t), strings.Repeat("x", 110))
	for _, args := range [][]string{
		{"server", "--server", dir},
		{"rpc", "--server", dir, "--client", "missing"},
		{"switch-window", "next", "--server", dir, "--client", "missing"},
	} {
		cmd := exec.Command(kidoBin, args...)
		cmd.Env = launcherEnv(t)
		out, err := cmd.CombinedOutput()
		if err == nil || !strings.Contains(string(out), "too long") || !strings.Contains(string(out), filepath.Join(dir, "socket")) {
			t.Errorf("%v: %v: %s", args, err, out)
		}
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatalf("long path created a directory: %v", err)
	}
}
