package e2e

import (
	"encoding/json"
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
			{"sidebar-feed", "--server", dir, "--client", "missing"},
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

func TestServerSocketPathTooLong(t *testing.T) {
	t.Parallel()
	requireTmux(t)
	dir := filepath.Join(serverDir(t), strings.Repeat("x", 110))
	for _, args := range [][]string{
		{"server", "--server", dir},
		{"sidebar-feed", "--server", dir, "--client", "missing"},
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

func TestStateDirectoryResolution(t *testing.T) {
	t.Parallel()
	requireTmux(t)
	base := serverDir(t)
	pane := filepath.Join(base, "pane")
	if err := os.Mkdir(pane, 0o700); err != nil {
		t.Fatal(err)
	}
	home := filepath.Join(base, "home")
	xdg := filepath.Join(base, "xdg")
	fallback := filepath.Join(base, "fallback")
	for _, c := range []struct {
		tmux, state, xdg, want string
		marker                 bool
	}{
		{"", "", "", filepath.Join(home, ".local/state/kido"), false},
		{"", "", xdg, filepath.Join(xdg, "kido"), false},
		{"", fallback, xdg, fallback, false},
		{filepath.Join(pane, "socket") + ",123,0", fallback, xdg, fallback, false},
		{filepath.Join(pane, "ordinary") + ",123,0", fallback, xdg, fallback, true},
		{filepath.Join(pane, "socket") + ",123,0", fallback, xdg, pane, true},
		{filepath.Join(pane, "socket") + ",123,0", "", "", pane, true},
	} {
		if c.marker {
			if err := os.WriteFile(filepath.Join(pane, "server.conf"), nil, 0o600); err != nil {
				t.Fatal(err)
			}
		}
		cmd := exec.Command(kidoBin, "get-inbox", "123")
		cmd.Env = cleanEnv("HOME="+home, "XDG_STATE_HOME="+c.xdg, "KIDO_STATE_DIR="+c.state, "TMUX="+c.tmux)
		out, err := cmd.CombinedOutput()
		var got struct {
			Path string `json:"path"`
		}
		if err != nil || json.Unmarshal(out, &got) != nil || got.Path != filepath.Join(c.want, "inbox/123.sock") {
			t.Fatalf("%+v: %v: %s", c, err, out)
		}
	}
}

func TestServerCreatesPrivateDirectory(t *testing.T) {
	t.Parallel()
	r := newKidoRun(t)
	r.state = filepath.Join(r.state, "new")
	r.kidoSock = filepath.Join(r.state, "socket")
	watchSocketPath(r.kidoSock)
	r.mustServer("")
	st, err := os.Stat(r.state)
	if err != nil || st.Mode().Perm() != 0o700 {
		t.Fatalf("created state directory: %v (%v), want 0700", st, err)
	}
}
