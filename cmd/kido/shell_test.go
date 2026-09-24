package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// TestShellArgv pins how each mode is exec'd, and the one case with a
// reason that is not obvious: an unprimed shell gets tmux's own dashed
// argv[0] rather than -l, because a shell kido knows nothing about is
// exactly the shell that might not take -l.
func TestShellArgv(t *testing.T) {
	cases := []struct {
		name    string
		path    string
		mode    primeMode
		command string
		want    []string
	}{
		{"zsh", "/bin/zsh", primeZsh, "", []string{"/bin/zsh", "-l"}},
		{"bash", "/bin/bash", primeBash, "", []string{"/bin/bash", "--login", "--posix"}},
		{"a shell kido does not know", "/usr/bin/fish", primePlain, "",
			[]string{"-fish"}},
		{"the user's own default-command", "/bin/zsh", primeZsh, "tmux-mem-cpu-load",
			[]string{"/bin/zsh", "-l", "-c", "tmux-mem-cpu-load"}},
		{"their command in a shell kido does not know", "/usr/bin/fish", primePlain, "top",
			[]string{"/usr/bin/fish", "-c", "top"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := shellArgv(c.path, c.mode, c.command); strings.Join(got, " ") != strings.Join(c.want, " ") {
				t.Errorf("shellArgv = %q, want %q", got, c.want)
			}
		})
	}
}

// TestWithEnv pins the replacement, which appending would not give: a
// session that already exports ZDOTDIR is the ordinary case for the zsh
// priming, and a second assignment after it is one the shell never
// reads. The assertion is a count, because "the new value is in there"
// holds for the broken version too.
func TestWithEnv(t *testing.T) {
	base := []string{"PATH=/bin", "ZDOTDIR=/home/me/dots", "TERM=xterm"}
	got := withEnv(base, []string{"ZDOTDIR=/tmp/kido-shell.1", "KIDO_ORIG_ZDOTDIR=/home/me/dots"})

	n := 0
	for _, kv := range got {
		if strings.HasPrefix(kv, "ZDOTDIR=") {
			n++
		}
	}
	if n != 1 {
		t.Errorf("environment %q holds %d ZDOTDIRs, want the one kido set", got, n)
	}
	if valueOf(t, got, "ZDOTDIR") != "/tmp/kido-shell.1" {
		t.Errorf("ZDOTDIR = %q, want kido's", valueOf(t, got, "ZDOTDIR"))
	}
	for _, want := range []string{"PATH=/bin", "TERM=xterm"} {
		if !has(got, strings.Split(want, "=")[0]) {
			t.Errorf("environment %q lost %q", got, want)
		}
	}
}

// TestResolveLoginShell pins the order, and that a default-shell naming a
// shell this host does not have costs the pane nothing.
func TestResolveLoginShell(t *testing.T) {
	real := filepath.Join(t.TempDir(), "myshell")
	if err := os.WriteFile(real, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name string
		in   []string
		want string
	}{
		{"the server's default-shell wins", []string{real, "/bin/bash"}, real},
		{"then $SHELL", []string{"", real}, real},
		{"an option naming nothing falls through", []string{"/no/such/shell", real}, real},
		{"and in the end /bin/sh", []string{"", ""}, "/bin/sh"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := resolveLoginShell(c.in...); got != c.want {
				t.Errorf("resolveLoginShell%q = %q, want %q", c.in, got, c.want)
			}
		})
	}
}

// TestPrimedZshReportsLocally is TestSSHPrimesAPristineZsh's local twin,
// and the claim `kido shell` is for: a zsh whose dotfiles know nothing
// about kido reports nothing, and the same zsh started the way `kido
// shell` starts it reports a prompt, a command line and an exit status.
// What ssh carries over the wire, this one does directly - which is the
// whole difference between the two callers - so it drives the priming
// plan and execs the shell itself rather than the command, whose one
// further step is the exec.
//
// Nothing is left behind: the .zshenv removes its own directory as it
// reads it, on this side exactly as on the far one.
func TestPrimedZshReportsLocally(t *testing.T) {
	zsh := interactiveZsh(t)
	home := zshHome(t, "")
	t.Setenv("HOME", home)
	os.Unsetenv("ZDOTDIR")
	script := "true\nexit\n"

	run := func(argv, env []string) string {
		t.Helper()
		cmd := noTTY(exec.Command(argv[0], argv[1:]...))
		cmd.Path = zsh
		cmd.Env = env
		cmd.Stdin = strings.NewReader(script)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("%q: %v\n%s", argv, err, out)
		}
		return string(out)
	}
	base := []string{"PATH=" + os.Getenv("PATH"), "HOME=" + home, "SHELL=" + zsh, "TERM=dumb"}

	if control := run([]string{zsh, "-l"}, base); osc133.MatchString(control) {
		t.Fatalf("the pristine shell already reports OSC 133 without kido; this test would prove nothing\n%q", control)
	}

	mode := localPrimeMode(zsh)
	if mode != primeZsh {
		t.Fatalf("localPrimeMode = %v for a zsh with dotfiles, want it primed", mode)
	}
	add, err := primeLocal(mode, "")
	if err != nil {
		t.Fatal(err)
	}
	dir := valueOf(t, add, "ZDOTDIR")
	out := run(shellArgv(zsh, mode, ""), append(base, add...))
	for _, want := range []string{"\x1b]133;A", "\x1b]133;C;cmdline=true", "\x1b]133;D;0"} {
		if !strings.Contains(out, want) {
			t.Errorf("primed output does not contain %q; it is %q", want, out)
		}
	}
	if _, err := os.Stat(dir); err == nil {
		t.Errorf("%s is still there; nothing kido writes for a shell may outlive it", dir)
	}
}

// TestPrimedZshPutsTheBinDirectoryFirst is why the prepend lives in the
// integration rather than only in the environment the pane inherits: a
// login file that rewrites PATH - macOS path_helper, run from
// /etc/zprofile, is the one every Mac has - demotes an inherited entry,
// and the integration runs after every login file. The unprimed run is the
// control: the same inherited PATH, the same .zprofile, and the directory
// no longer first. It is also run with the directory already inherited,
// so a nested shell cannot grow PATH.
func TestPrimedZshPutsTheBinDirectoryFirst(t *testing.T) {
	zsh := interactiveZsh(t)
	home := zshHome(t, "")
	if err := os.WriteFile(filepath.Join(home, ".zprofile"), []byte("PATH=/usr/bin:/bin:$PATH\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	os.Unsetenv("ZDOTDIR")
	bin := filepath.Join(t.TempDir(), "kido bin")
	inherited := bin + ":/usr/bin:/bin"
	path := regexp.MustCompile(`PATH<([^>]*)>`)

	run := func(argv, add []string) string {
		t.Helper()
		cmd := noTTY(exec.Command(argv[0], argv[1:]...))
		cmd.Path = zsh
		cmd.Env = append([]string{"PATH=" + inherited, "HOME=" + home, "SHELL=" + zsh, "TERM=dumb"}, add...)
		cmd.Stdin = strings.NewReader("printf 'PATH<%s>\\n' \"$PATH\"\nexit\n")
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("%q: %v\n%s", argv, err, out)
		}
		// The last match: a primed shell reports the command line too,
		// with the unexpanded %s in it.
		m := path.FindAllStringSubmatch(string(out), -1)
		if m == nil {
			t.Fatalf("%q printed no PATH: %q", argv, out)
		}
		return m[len(m)-1][1]
	}

	if got := run([]string{zsh, "-l"}, nil); strings.HasPrefix(got, bin+":") {
		t.Fatalf("PATH = %q unprimed: the .zprofile did not demote the directory, so this test proves nothing", got)
	}
	add, err := primeLocal(primeZsh, bin)
	if err != nil {
		t.Fatal(err)
	}
	got := run(shellArgv(zsh, primeZsh, ""), add)
	if !strings.HasPrefix(got, bin+":") || strings.Count(got, bin) != 1 {
		t.Errorf("PATH = %q primed, want %q first and once", got, bin)
	}
}
