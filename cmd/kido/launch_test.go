package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func serverConf(t *testing.T, exe string) string {
	t.Helper()
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(t.TempDir(), "config"))
	old := os.Args[0]
	os.Args[0] = exe
	defer func() { os.Args[0] = old }()

	path, err := writeServerConf()
	if err != nil {
		t.Fatalf("writeServerConf: %v", err)
	}
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(body)
}

func fakeKido(t *testing.T) string {
	t.Helper()
	exe := filepath.Join(t.TempDir(), "kido")
	if err := os.WriteFile(exe, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return exe
}

// lineAfter is the index of the first generated line containing sub, or
// -1.
func lineAfter(conf, sub string) int {
	for i, line := range strings.Split(conf, "\n") {
		if strings.Contains(line, sub) {
			return i
		}
	}
	return -1
}

// lastLine is lineAfter from the other end, which is the one that
// counts for an option set more than once: the server ends up with the
// launcher's later line, not kido's own default.
func lastLine(conf, sub string) int {
	at := -1
	for i, line := range strings.Split(conf, "\n") {
		if strings.Contains(line, sub) {
			at = i
		}
	}
	return at
}

// TestServerConfLayersInOrder pins the configuration's layer order:
// kido's defaults first, then the user's kido.conf, then the two options
// kido owns - and the user's own default-command captured in between,
// since after the override there is nothing left to capture. It asserts
// positions rather than presence: a file that sources the user's config
// last would satisfy "every line is there" while quietly leaving the
// server with no sidebar at all.
func TestServerConfLayersInOrder(t *testing.T) {
	exe := fakeKido(t)
	conf := serverConf(t, exe)

	defaults := lineAfter(conf, "side-status-width")
	source := lineAfter(conf, "source-file -q")
	capture := lineAfter(conf, "@kido-user-command")
	side := lastLine(conf, "set -g side-status-command")
	command := lastLine(conf, "set -g default-command")
	for name, at := range map[string]int{
		"kido's defaults": defaults, "source-file of kido.conf": source,
		"the default-command capture": capture, "side-status-command": side,
		"default-command": command,
	} {
		if at < 0 {
			t.Fatalf("the generated config has no %s:\n%s", name, conf)
		}
	}
	if !(defaults < source && source < capture && capture < side && side < command) {
		t.Errorf("layers out of order (defaults %d, kido.conf %d, capture %d, side %d, command %d):\n%s",
			defaults, source, capture, side, command, conf)
	}
	if lines := strings.Split(conf, "\n"); !strings.Contains(lines[side], `'`+exe+`'`) {
		t.Errorf("the last side-status-command is %q, not the kido binary %s", lines[side], exe)
	}
	if !strings.Contains(conf, `'`+exe+` shell'`) {
		t.Errorf("default-command is not `%s shell`:\n%s", exe, conf)
	}
}

// TestServerConfNamesTheUsersKidoConf pins where the user's file is
// looked for, and that ~/.tmux.conf is not among the places: a tmux
// configuration written for stock tmux fights the side column.
func TestServerConfNamesTheUsersKidoConf(t *testing.T) {
	conf := serverConf(t, fakeKido(t))
	if want := filepath.Join(os.Getenv("XDG_CONFIG_HOME"), "kido", "kido.conf"); !strings.Contains(conf, want) {
		t.Errorf("the generated config does not source %s:\n%s", want, conf)
	}
	if strings.Contains(conf, ".tmux.conf") {
		t.Errorf("the generated config reads the user's tmux.conf:\n%s", conf)
	}

	t.Setenv("XDG_CONFIG_HOME", "")
	home := t.TempDir()
	t.Setenv("HOME", home)
	got, err := userConfPath()
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(home, ".config", "kido", "kido.conf"); got != want {
		t.Errorf("userConfPath = %q, want %q", got, want)
	}
}

// TestConfCommandLeavesAnUnquotedPathParseable: confCommand only
// double-quotes a path when it needs to. The result is also what tmux's
// default_window_name() (third_party/tmux/names.c) parses to name a
// window when automatic-rename is off, and that function undoes at most
// one layer of quoting; see TestFirstWindowNameIsNotQuoteDebris (e2e)
// for the claim on tmux's own C side.
func TestConfCommandLeavesAnUnquotedPathParseable(t *testing.T) {
	got, err := confCommand("/opt/homebrew/bin/kido", "shell")
	if err != nil {
		t.Fatal(err)
	}
	if want := "'/opt/homebrew/bin/kido shell'"; got != want {
		t.Errorf("confCommand = %q, want %q", got, want)
	}
}

// TestConfCommandQuotesAPathWithASpace is the case confCommand cannot
// avoid double-quoting: the runtime shell (`$SHELL -c "<default-command>"`)
// would otherwise split the path itself into two words.
func TestConfCommandQuotesAPathWithASpace(t *testing.T) {
	got, err := confCommand("/Application Support/kido", "shell")
	if err != nil {
		t.Fatal(err)
	}
	if want := `'"/Application Support/kido" shell'`; got != want {
		t.Errorf("confCommand = %q, want %q", got, want)
	}
}

// TestServerConfRefusesAnUnquotablePath pins that a path no nesting of
// tmux and sh quoting can carry is refused up front, rather than written
// into a file that would fail at server start on a line the user did not
// write.
func TestServerConfRefusesAnUnquotablePath(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "we're here")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(dir, "kido")
	if err := os.WriteFile(exe, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	old := os.Args[0]
	os.Args[0] = exe
	defer func() { os.Args[0] = old }()

	if _, err := writeServerConf(); err == nil {
		t.Fatal("a kido installed under a path with a quote in it generated a config anyway")
	}
}

// TestProbeServer pins the reading of the tmux failures kido translates.
// The mismatch wording is tmux's, from client.c; the other two cases are
// what it says with no server and with a socket it cannot reach, and
// both mean "start one".
func TestProbeServer(t *testing.T) {
	cases := []struct {
		name   string
		exit   int
		stderr string
		want   serverState
	}{
		{"a server that answered", 0, "", serverUp},
		{"an older kido-tmux still running", 1,
			"protocol version mismatch (client 8, server 7)", serverMismatch},
		{"no server at all", 1,
			"no server running on /tmp/tmux-501/kido", serverDown},
		{"a socket that cannot be reached", 1,
			"error connecting to /tmp/tmux-501/kido (No such file or directory)", serverDown},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			bin := filepath.Join(t.TempDir(), "tmux")
			script := fmt.Sprintf("#!/bin/sh\necho '%s' >&2\nexit %d\n", c.stderr, c.exit)
			if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
				t.Fatal(err)
			}
			if got := probeServer(bin); got != c.want {
				t.Errorf("probeServer = %v, want %v", got, c.want)
			}
		})
	}
}

// TestLaunchRefusesInsideTmux pins the refusal, and that it names the
// socket the terminal is already on.
func TestLaunchRefusesInsideTmux(t *testing.T) {
	t.Setenv("TMUX", "/tmp/tmux-501/kido,1234,0")
	err := launch()
	if err == nil {
		t.Fatal("launch inside tmux returned no error")
	}
	if !strings.Contains(err.Error(), "plain terminal") {
		t.Errorf("error %q does not say where to run kido from", err)
	}
	if !strings.Contains(err.Error(), "/tmp/tmux-501/kido") {
		t.Errorf("error %q does not name the tmux already in charge", err)
	}
}
