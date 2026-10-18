package e2e

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"
)

// Inside a kido pane, tmux, ssh and pi resolve to the shims in
// <share>/bin: put first on PATH by the launcher for the server, and by
// the primed shell's integration after the user's login files. These
// tests type into a launched kido pane, the only place the second
// happens.

func (r *kidoRun) shellIn(pane, command string) string {
	r.t.Helper()
	out := filepath.Join(r.dir, fmt.Sprintf("out-%d", time.Now().UnixNano()))
	r.mustKido("send-keys", "-t", pane,
		fmt.Sprintf("{ %s ; } >%q 2>&1; mv %q %q", command, out+".tmp", out+".tmp", out), "Enter")
	var body string
	r.waitFor(func() bool {
		b, err := os.ReadFile(out)
		body = string(b)
		return err == nil
	}, "the pane to run "+command)
	return strings.TrimRight(body, "\n")
}

// primedPane's shell has reached a prompt, i.e. run the integration.
func (r *kidoRun) primedPane() string {
	r.t.Helper()
	r.launch("first")
	r.waitUp()
	pane := r.firstPane()
	r.waitFor(func() bool {
		return reportedPrompt(r.mustKido("display-message", "-p", "-t", pane, "#{pane_last_prompt_time}"))
	}, "the pane's shell to report its first prompt")
	return pane
}

func sameFile(a, b string) bool {
	fa, errA := os.Stat(a)
	fb, errB := os.Stat(b)
	return errA == nil && errB == nil && os.SameFile(fa, fb)
}

// `tmux` and `ssh` resolve to the shims in a kido pane, and the shimmed
// tmux reaches the kido server's own socket. run-shell resolves the shim
// too: what tmux runs with no shell in between has only the server's
// PATH.
//
// On macOS the pane's login zsh runs path_helper from /etc/zprofile,
// putting system directories back in front of an inherited PATH. The
// nested `zsh -l -c` control shows that: same inherited PATH, no
// integration after it, system ssh wins - otherwise a shim found first
// could just be the launcher's PATH surviving an untouched login.
func TestKidoPaneRunsTheShims(t *testing.T) {
	t.Parallel()
	r := newKidoRun(t)
	pane := r.primedPane()
	shims := filepath.Join(shareDir, "bin")

	for _, name := range []string{"kido", "tmux", "ssh"} {
		if got := r.shellIn(pane, "command -v "+name); !sameFile(got, filepath.Join(shims, name)) {
			t.Errorf("command -v %s = %q in a kido pane, want the shim in %s", name, got, shims)
		}
	}
	version, err := exec.Command(kidoBin, "--version").Output()
	if err != nil {
		t.Fatal(err)
	}
	if got := r.shellIn(pane, "kido --version"); got != strings.TrimSpace(string(version)) {
		t.Errorf("shim kido version = %q, prefix binary = %q", got, version)
	}
	if got := r.mustKido("run-shell", "command -v kido"); !sameFile(got, filepath.Join(shims, "kido")) {
		t.Errorf("server kido = %q, want its own shim", got)
	}
	want := r.mustKido("display-message", "-p", "#{socket_path}")
	if got := r.shellIn(pane, "tmux display-message -p '#{socket_path}'"); got != want {
		t.Errorf("tmux display-message in a kido pane printed %q, want the kido server's socket %q", got, want)
	}
	if got := r.mustKido("run-shell", "command -v tmux"); !sameFile(got, filepath.Join(shims, "tmux")) {
		t.Errorf("run-shell 'command -v tmux' = %q, want the shim in %s", got, shims)
	}

	if runtime.GOOS == "darwin" && filepath.Base(r.shell) == "zsh" {
		if got := r.shellIn(pane, "zsh -l -c 'command -v ssh'"); sameFile(got, filepath.Join(shims, "ssh")) {
			t.Errorf("a login zsh with no integration still finds %q: path_helper demoted nothing, so the pane proves nothing", got)
		}
	}
}

// fakeRealPrograms puts recording ssh, pi and claude on PATH from the
// user's own rc file, after the login files - where a user's PATH edits
// live and macOS path_helper does not reorder. Each call writes its
// arguments, NUL-separated, into its own file under calls.
func (r *kidoRun) fakeRealPrograms() (calls string) {
	r.t.Helper()
	fakes := filepath.Join(r.dir, "fakes")
	calls = filepath.Join(r.dir, "calls")
	for _, d := range []string{fakes, calls} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			r.t.Fatal(err)
		}
	}
	for _, name := range []string{"ssh", "pi", "claude"} {
		body := fmt.Sprintf("#!/bin/sh\n[ \"$1\" = -G ] && exit 1\nf=$(mktemp %q)\nprintf '%%s\\0' %q \"$@\" >\"$f\"\n",
			filepath.Join(calls, name+".XXXXXX"), name)
		if err := os.WriteFile(filepath.Join(fakes, name), []byte(body), 0o755); err != nil {
			r.t.Fatal(err)
		}
	}
	line := fmt.Sprintf("\nPATH=%q:$PATH\n", fakes)
	for _, rc := range []string{".zshrc", ".bash_profile"} {
		f, err := os.OpenFile(filepath.Join(r.home, rc), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err != nil {
			r.t.Fatal(err)
		}
		f.WriteString(line)
		f.Close()
	}
	return calls
}

func (r *kidoRun) nextCall(calls string, seen map[string]bool) (string, []string) {
	r.t.Helper()
	var name string
	var args []string
	r.waitFor(func() bool {
		entries, _ := os.ReadDir(calls)
		for _, e := range entries {
			if seen[e.Name()] {
				continue
			}
			b, err := os.ReadFile(filepath.Join(calls, e.Name()))
			if err != nil || len(b) == 0 {
				continue
			}
			seen[e.Name()] = true
			argv := strings.Split(strings.TrimSuffix(string(b), "\x00"), "\x00")
			name, args = argv[0], argv[1:]
			return true
		}
		return false
	}, "a call to reach a real program")
	return name, args
}

// Each shim ends in the real program with the user's arguments intact
// and kido's in front of them. ssh covers both shapes: passed through as
// typed (spacing must survive) and primed (gains -t and the bootstrap).
func TestShimsReachTheRealPrograms(t *testing.T) {
	t.Parallel()
	r := newKidoRun(t)
	calls := r.fakeRealPrograms()
	pane := r.primedPane()
	seen := map[string]bool{}
	run := func(command string) (string, []string) {
		t.Helper()
		r.mustKido("send-keys", "-t", pane, command, "Enter")
		return r.nextCall(calls, seen)
	}

	if name, args := run("ssh -V"); name != "ssh" || !slices.Equal(args, []string{"-V"}) {
		t.Errorf("ssh -V reached %s %q, want the real ssh with -V alone", name, args)
	}
	if name, args := run("ssh host 'echo a  b'"); name != "ssh" || !slices.Equal(args, []string{"host", "echo a  b"}) {
		t.Errorf("ssh host 'echo a  b' reached %s %q", name, args)
	}
	if name, args := run("ssh host"); name != "ssh" || len(args) != 4 ||
		!slices.Equal(args[:3], []string{"-t", "--", "host"}) || !strings.Contains(args[3], "kido_zsh_b64=") {
		t.Errorf("an interactive ssh host reached %s %q, want -t -- host and the bootstrap", name, args)
	}
	// Anything but an interactive session with a terminal on stdin passes
	// through as typed, primed ones keep the user's options ahead of -t, and
	// an option's value is not read as more option letters.
	for _, passed := range []string{"host uptime", "-N -L 8080:localhost:80 host", "-T host",
		"-W other:22 host", "-f host", "-s host sftp", "-O check host",
		"host -T", "host -s sftp", "-- host -p 2222", "host -- -p 2222"} {
		if name, args := run("ssh " + passed); name != "ssh" || !slices.Equal(args, strings.Fields(passed)) {
			t.Errorf("ssh %s reached %s %q, want it unprimed", passed, name, args)
		}
	}
	for _, passed := range []string{"host -i", "-i"} {
		r.mustKido("set-option", "-p", "-t", pane, "@kido_ssh_args", `["old-host"]`)
		if name, args := run("ssh " + passed); name != "ssh" || !slices.Equal(args, strings.Fields(passed)) {
			t.Errorf("ssh %s reached %s %q, want unchanged arguments", passed, name, args)
		}
		if got := r.mustKido("show-options", "-p", "-t", pane); strings.Contains(got, "@kido_ssh_args") {
			t.Errorf("ssh %s kept recorded arguments: %s", passed, got)
		}
	}
	if name, args := run("true | ssh host"); name != "ssh" || !slices.Equal(args, []string{"host"}) {
		t.Errorf("ssh host with a pipe on stdin reached %s %q, want it unprimed", name, args)
	}
	for _, c := range []struct{ typed, want string }{
		{"-o BatchMode=yes -A deploy@host", "-o BatchMode=yes -A -t -- deploy@host"},
		{"-o ProxyCommand=none -p 22 host", "-o ProxyCommand=none -p 22 -t -- host"},
		{"host -p 2222", "-p 2222 -t -- host"},
		{"-- host", "-t -- host"},
		{"host --", "-t -- host"},
	} {
		name, args := run("ssh " + c.typed)
		if n := len(args); name != "ssh" || n == 0 || !slices.Equal(args[:n-1], strings.Fields(c.want)) ||
			!strings.Contains(args[n-1], "kido_zsh_b64=") {
			t.Errorf("ssh %s reached %s %q, want %s and the bootstrap", c.typed, name, args, c.want)
		}
	}

	name, args := run("pi 'hello  there'")
	if name != "pi" || !slices.Equal(args, []string{"hello  there"}) {
		t.Fatalf("pi reached %s %q, want plain pi with unmodified user arguments", name, args)
	}
	name, args = run("kido-pi 'hello  there'")
	if name != "pi" || len(args) != 3 || args[0] != "--extension" || args[2] != "hello  there" {
		t.Fatalf("kido-pi reached %s %q, want one --extension and the message", name, args)
	}
	if !sameFile(args[1], filepath.Join(shareDir, "pi", "kido-pi.ts")) {
		t.Errorf("--extension %s, want the shipped kido-pi.ts", args[1])
	}

	name, args = run("claude -p hi")
	if name != "claude" || !slices.Equal(args, []string{"-p", "hi"}) {
		t.Fatalf("claude reached %s %q, want unmodified user arguments", name, args)
	}
}
