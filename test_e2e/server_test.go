package e2e

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// endpoint is the one line `kido server` prints, the contract Kido.app
// reads.
type endpoint struct {
	Tmux     string `json:"tmux"`
	Socket   string `json:"socket"`
	Protocol string `json:"protocol"`
	Server   string `json:"server"`
}

// server runs `kido server` in this test's world with TMUX set to tmux,
// returning its stdout, stderr and exit code.
func (r *kidoRun) server(tmux string) (string, string, int) {
	r.t.Helper()
	cmd := exec.Command(kidoBin, "server", "--server", r.state)
	cmd.Env = cleanEnv(append(r.env(), "TMUX="+tmux, "TMUX_SIDE_CLIENT=")...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	done := make(chan struct{})
	go func() { cmd.Run(); close(done) }()
	select {
	case <-done:
	case <-time.After(settle):
		cmd.Process.Kill()
		<-done
		r.t.Fatalf("kido server did not return within %s: %s", settle, stderr.String())
	}
	return stdout.String(), stderr.String(), cmd.ProcessState.ExitCode()
}

// mustServer runs `kido server` and checks the line it printed names the
// kido-tmux beside kido, unresolved, and the socket this test's server
// is on.
func (r *kidoRun) mustServer(tmux string) endpoint {
	r.t.Helper()
	out, errOut, code := r.server(tmux)
	if code != 0 {
		r.t.Fatalf("kido server: exit %d, stderr %q", code, errOut)
	}
	if strings.Count(out, "\n") != 1 || !strings.HasSuffix(out, "\n") {
		r.t.Fatalf("kido server printed %q, want exactly one line", out)
	}
	var e endpoint
	if err := json.Unmarshal([]byte(out), &e); err != nil {
		r.t.Fatalf("kido server printed %q: %v", out, err)
	}
	if want := filepath.Join(filepath.Dir(kidoBin), "kido-tmux"); e.Tmux != want {
		r.t.Errorf("tmux = %q, want %q", e.Tmux, want)
	}
	if !filepath.IsAbs(e.Socket) || !sameFile(e.Socket, r.kidoSock) {
		r.t.Errorf("socket = %q, want the absolute path of %s", e.Socket, r.kidoSock)
	}
	if e.Protocol != "2.1" {
		r.t.Errorf("binary protocol = %q, want 2.1", e.Protocol)
	}
	return e
}

// With no server, `kido server` starts one as the launcher would -
// server.conf applied, session main - but attaches nothing: no client at
// all, not even the sidebar's control connection, which only a real
// client brings. Called again, it answers from the same server: its pid is
// the one the first call started.
func TestKidoServerStartsTheServerDetached(t *testing.T) {
	t.Parallel()
	r := newKidoRun(t)
	confDir := filepath.Join(r.config, "kido")
	if err := os.MkdirAll(confDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(confDir, "kido.conf"), []byte("set -g @kido-e2e from-kido-conf\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	first := r.mustServer("")
	if first.Server != "2.1" {
		t.Fatalf("server stamp = %q, want 2.1", first.Server)
	}
	if got := r.mustKido("list-sessions", "-F", "#{session_name} #{session_attached}"); got != "main 0" {
		t.Errorf("sessions = %q, want main, detached", got)
	}
	if got := r.mustKido("list-clients"); got != "" {
		t.Errorf("clients = %q, want none", got)
	}
	if got := r.mustKido("show-options", "-gv", "@kido-e2e"); got != "from-kido-conf" {
		t.Errorf("@kido-e2e = %q, want the value kido.conf set", got)
	}
	if got := r.mustKido("show-options", "-gv", "side-status-command"); !strings.Contains(got, kidoBin) {
		t.Errorf("side-status-command = %q, want the kido under test", got)
	}
	pid := r.mustKido("display-message", "-p", "#{pid}")

	if second := r.mustServer(""); second != first {
		t.Errorf("second kido server printed %+v, want %+v", second, first)
	}
	if got := r.mustKido("display-message", "-p", "#{pid}"); got != pid {
		t.Errorf("server pid = %s after the second call, want %s", got, pid)
	}
	if got := r.mustKido("list-sessions", "-F", "#{session_name}"); got != "main" {
		t.Errorf("sessions = %q, want only main", got)
	}
	r.mustKido("set-environment", "-g", "KIDO_PROTOCOL", "another-protocol")
	if got := r.mustServer("").Server; got != "another-protocol" {
		t.Errorf("existing server stamp = %q, want another-protocol", got)
	}
	r.mustKido("set-environment", "-gu", "KIDO_PROTOCOL")
	out, _, code := r.server("")
	if code != 0 || !strings.Contains(out, `"protocol":"2.1","server":null`) {
		t.Errorf("unstamped server: exit %d, JSON %q, want protocol:2.1 and server:null", code, out)
	}
}

// Inside tmux it does what it does outside: the launcher's refusal is
// about attaching, which `kido server` never does.
func TestKidoServerInsideTmux(t *testing.T) {
	t.Parallel()
	r := newKidoRun(t)
	r.mustServer("/tmp/tmux-1/default,1234,0")
	if got := r.mustKido("list-sessions", "-F", "#{session_name}"); got != "main" {
		t.Errorf("sessions = %q, want main", got)
	}
}

// Several apps launching at once: whichever loses the race to create
// session main still answers with the server the winner started.
func TestKidoServerRacesSucceed(t *testing.T) {
	t.Parallel()
	r := newKidoRun(t)
	var wg sync.WaitGroup
	results := make([]string, 4)
	for i := range results {
		wg.Add(1)
		go func() {
			defer wg.Done()
			out, errOut, code := r.server("")
			results[i] = fmt.Sprintf("exit %d: %s%s", code, out, errOut)
		}()
	}
	wg.Wait()
	for _, got := range results[1:] {
		if got != results[0] || !strings.HasPrefix(got, "exit 0: ") {
			t.Fatalf("racing kido servers answered %q", results)
		}
	}
	if got := r.mustKido("list-sessions", "-F", "#{session_name}"); got != "main" {
		t.Errorf("sessions = %q, want only main", got)
	}
}

// tmux blocks only the starting client while reading config. A second
// client must see the startup protocol even before the owned options run.
func TestKidoServerProtocolDuringConfig(t *testing.T) {
	t.Parallel()
	r := newKidoRun(t)
	confDir := filepath.Join(r.config, "kido")
	if err := os.MkdirAll(confDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(confDir, "kido.conf"),
		[]byte("new-session -d -s bootstrap\nrun-shell 'sleep 1'\nset -g @config-finished yes\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	started := make(chan string, 1)
	go func() {
		out, errOut, code := r.server("")
		started <- fmt.Sprintf("exit %d: %s%s", code, out, errOut)
	}()
	r.waitUp()
	if got := r.mustKido("display-message", "-p", "#{@config-finished}"); got != "" {
		t.Fatal("configuration finished before the racing probe")
	}
	out, errOut, code := r.server("")
	finished := r.mustKido("display-message", "-p", "#{@config-finished}")
	first := <-started
	if finished != "" {
		t.Fatal("configuration finished before the racing probe returned")
	}
	second := fmt.Sprintf("exit %d: %s%s", code, out, errOut)
	if second != first || !strings.HasPrefix(first, "exit 0: ") {
		t.Fatalf("during config: %q; starting client: %q", second, first)
	}
}

// A server from another kido-tmux refuses the probe: the launcher's
// message, under this subcommand's name, exit 1, and nothing started.
func TestKidoServerMismatch(t *testing.T) {
	t.Parallel()
	requireTmux(t)
	mismatch := writeScript(t, filepath.Join(t.TempDir(), "old-tmux"),
		"#!/bin/sh\necho 'protocol version mismatch (client 8, server 7)' >&2\nexit 1\n")
	env := launcherEnv(t, "KIDO_TMUX="+mismatch)
	cmd := exec.Command(kidoBin, "server")
	cmd.Env = env
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	cmd.Run()
	const want = `kido server: the kido server on socket `
	if code := cmd.ProcessState.ExitCode(); code != 1 || !strings.HasPrefix(stderr.String(), want) || stdout.Len() != 0 {
		t.Errorf("exit %d, stdout %q, stderr %q; want exit 1, no stdout and %q", code, stdout.String(), stderr.String(), want)
	}
}
