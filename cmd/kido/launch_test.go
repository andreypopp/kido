package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// serverConf generates the configuration the launcher starts a server
// with, for a kido at exe, and returns its text. It owns the environment
// the generator reads: the state directory it writes into and the config
// home it points the user's file at.
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

// fakeKido writes an executable standing in for an installed kido, so
// invokedPath has a real file to resolve and the generated configuration
// names an absolute path.
func fakeKido(t *testing.T) string {
	t.Helper()
	exe := filepath.Join(t.TempDir(), "kido")
	if err := os.WriteFile(exe, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return exe
}

// lineAfter is the index of the first generated line containing sub, or
// -1. The tests below are about the order of three layers, so they read
// positions rather than presence.
func lineAfter(conf, sub string) int {
	for i, line := range strings.Split(conf, "\n") {
		if strings.Contains(line, sub) {
			return i
		}
	}
	return -1
}

// lastLine is lineAfter from the other end, which is the one that counts
// for an option set more than once: kido's defaults name side-status-command
// by the bare word "kido", for a user running the sidebar inside their
// own tmux, and it is the launcher's later line - the absolute path - that
// the server ends up with.
func lastLine(conf, sub string) int {
	at := -1
	for i, line := range strings.Split(conf, "\n") {
		if strings.Contains(line, sub) {
			at = i
		}
	}
	return at
}

// TestServerConfLayersInOrder is the whole of the configuration decision:
// kido's defaults first, then the user's kido.conf, then the two options
// kido owns - and the user's own default-command captured in between,
// because after the override there is nothing left to capture.
//
// It asserts positions rather than presence. Every line being there is
// satisfied by a file that sources the user's config last, which is the
// arrangement where a kido.conf setting side-status-command quietly
// leaves the server with no sidebar at all.
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
	if lines := strings.Split(conf, "\n"); !strings.Contains(lines[side], `'"`+exe+`"'`) {
		t.Errorf("the last side-status-command is %q, not the kido binary %s", lines[side], exe)
	}
	if !strings.Contains(conf, `'"`+exe+`" shell'`) {
		t.Errorf("default-command is not `%s shell`:\n%s", exe, conf)
	}
}

// TestServerConfNamesTheUsersKidoConf pins where the user's file is
// looked for, and that ~/.tmux.conf is not among the places: a tmux
// configuration written for stock tmux fights the side column, so reading
// it is a decision, not an omission.
func TestServerConfNamesTheUsersKidoConf(t *testing.T) {
	conf := serverConf(t, fakeKido(t))
	if want := filepath.Join(os.Getenv("XDG_CONFIG_HOME"), "kido", "kido.conf"); !strings.Contains(conf, want) {
		t.Errorf("the generated config does not source %s:\n%s", want, conf)
	}
	if strings.Contains(conf, ".tmux.conf") {
		t.Errorf("the generated config reads the user's tmux.conf:\n%s", conf)
	}

	// The same file with no XDG_CONFIG_HOME set, which is where most
	// users' is.
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

// TestServerConfRefusesAnUnquotablePath pins that a path no nesting of
// tmux and sh quoting can carry is refused up front rather than written
// into a file that would fail at server start with tmux's error, on a
// line the user did not write.
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

// TestClassifyProbe pins the reading of the one tmux failure kido
// translates. The mismatch wording is tmux's, from client.c; the other
// two cases are what it says with no server and with a socket it cannot
// reach, and both mean "start one".
func TestClassifyProbe(t *testing.T) {
	cases := []struct {
		name   string
		err    error
		stderr string
		want   serverState
	}{
		{"a server that answered", nil, "", serverUp},
		{"an older kido-tmux still running", errors.New("exit status 1"),
			"protocol version mismatch (client 8, server 7)\n", serverMismatch},
		{"no server at all", errors.New("exit status 1"),
			"no server running on /tmp/tmux-501/kido\n", serverDown},
		{"a socket that cannot be reached", errors.New("exit status 1"),
			"error connecting to /tmp/tmux-501/kido (No such file or directory)\n", serverDown},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := classifyProbe(c.err, c.stderr); got != c.want {
				t.Errorf("classifyProbe = %v, want %v", got, c.want)
			}
		})
	}
}

// TestLaunchRefusesInsideTmux pins the refusal, and that it names the
// socket the terminal is already on. Nothing is started: launch returns
// before it has looked for a server at all, which is the only way a
// refusal can be one.
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
