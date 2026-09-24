package main

import (
	"bytes"
	"encoding/base64"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"syscall"
	"testing"

	"kido/shell"
)

// noTTY runs cmd in its own session, detached from this process's
// controlling terminal: an interactive zsh prefers /dev/tty over a piped
// stdin whenever one is attached, and every command here either is that
// zsh or execs into it via the bootstrap.
func noTTY(cmd *exec.Cmd) *exec.Cmd {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	return cmd
}

// TestParseSSHSplitsAtTheDestination pins where kido thinks the
// destination is, which is the whole of what it needs from an ssh command
// line: everything before it is passed through untouched, and anything
// after it is a remote command kido must not displace.
func TestParseSSHSplitsAtTheDestination(t *testing.T) {
	cases := []struct {
		name    string
		args    []string
		opts    []string
		dest    string
		command []string
	}{
		{"bare", []string{"host"}, nil, "host", nil},
		{"user@host", []string{"deploy@host"}, nil, "deploy@host", nil},
		{"flag then host", []string{"-A", "host"}, []string{"-A"}, "host", nil},
		{"bundled flags", []string{"-tt", "host"}, []string{"-tt"}, "host", nil},
		// -o takes its value from the next argument, so the host is the
		// third: reading it as the second would send the bootstrap to a
		// destination called "BatchMode=yes".
		{"separate value", []string{"-o", "BatchMode=yes", "host"},
			[]string{"-o", "BatchMode=yes"}, "host", nil},
		{"attached value", []string{"-oBatchMode=yes", "host"},
			[]string{"-oBatchMode=yes"}, "host", nil},
		{"attached port", []string{"-p2222", "host"}, []string{"-p2222"}, "host", nil},
		{"value after bundle", []string{"-4p", "2222", "host"},
			[]string{"-4p", "2222"}, "host", nil},
		{"remote command", []string{"host", "uptime", "-a"}, nil, "host", []string{"uptime", "-a"}},
		{"no destination", []string{"-V"}, []string{"-V"}, "", nil},
		{"nothing", nil, nil, "", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			in := parseSSH(c.args)
			if !slices.Equal(in.opts, c.opts) {
				t.Errorf("opts = %q, want %q", in.opts, c.opts)
			}
			if in.dest != c.dest {
				t.Errorf("dest = %q, want %q", in.dest, c.dest)
			}
			if !slices.Equal(in.command, c.command) {
				t.Errorf("command = %q, want %q", in.command, c.command)
			}
		})
	}
}

// TestParseSSHLettersExcludeValues pins that an option's value is not
// read as more option letters: `-o ProxyCommand=none` carries an N, a T
// and a W among others, every one of which would make kido decide this
// connection has no shell to prime.
func TestParseSSHLettersExcludeValues(t *testing.T) {
	in := parseSSH([]string{"-o", "ProxyCommand=none", "-p", "22", "host"})
	if got, want := in.letters, "op"; got != want {
		t.Errorf("letters = %q, want %q", got, want)
	}
	if !in.canPrime(true) {
		t.Error("an ssh with -o and -p is an ordinary interactive session; kido should prime it")
	}
}

// TestSSHArgsPassesThroughWhatItCannotPrime is the degrade-never-break
// half: every one of these must reach ssh exactly as the user spelled it,
// with no -t and no remote command added. `kido ssh` is not allowed to be
// worse than `ssh`.
func TestSSHArgsPassesThroughWhatItCannotPrime(t *testing.T) {
	cases := []struct {
		name string
		args []string
		tty  bool
	}{
		{"no tty", []string{"host"}, false},
		{"a remote command of the user's own", []string{"host", "uptime"}, true},
		{"no destination", []string{"-V"}, true},
		{"-N, no shell at all", []string{"-N", "-L", "8080:localhost:80", "host"}, true},
		{"-T, a tty refused", []string{"-T", "host"}, true},
		{"-W, stdio forwarding", []string{"-W", "other:22", "host"}, true},
		{"-f, backgrounded", []string{"-f", "host"}, true},
		{"-s, a subsystem", []string{"-s", "host", "sftp"}, true},
		{"-O, a control command", []string{"-O", "check", "host"}, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := sshArgs(c.args, c.tty)
			want := append([]string{"ssh"}, c.args...)
			if !slices.Equal(got, want) {
				t.Errorf("sshArgs(%q, %v) = %q, want it passed through as %q", c.args, c.tty, got, want)
			}
		})
	}
}

// TestSSHArgsPrimes pins the primed command line: the user's options in
// the order they were given, then -t (ssh allocates no tty for a command,
// and the shell kido asks for is an interactive one), the destination,
// and the bootstrap as the remote command.
func TestSSHArgsPrimes(t *testing.T) {
	got := sshArgs([]string{"-o", "BatchMode=yes", "-A", "deploy@host"}, true)
	if len(got) < 6 {
		t.Fatalf("sshArgs = %q, want a primed command line", got)
	}
	head, tail := got[:len(got)-1], got[len(got)-1]
	want := []string{"ssh", "-o", "BatchMode=yes", "-A", "-t", "deploy@host"}
	if !slices.Equal(head, want) {
		t.Errorf("primed command line = %q, want %q followed by the bootstrap", head, want)
	}
	if tail != sshBootstrap() {
		t.Errorf("last argument is not the bootstrap: %q", tail)
	}
}

// TestSSHBootstrapIsAShellProgram checks the bootstrap parses as POSIX
// sh. It is assembled by string formatting and sent to a remote shell
// that reports a syntax error as a broken login, so the cheapest possible
// check is worth having.
func TestSSHBootstrapIsAShellProgram(t *testing.T) {
	sh, err := exec.LookPath("sh")
	if err != nil {
		t.Skip("no sh in PATH")
	}
	cmd := exec.Command(sh, "-n")
	cmd.Stdin = strings.NewReader(sshBootstrap())
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("sh -n: %v\n%s", err, out)
	}
}

// TestKidoZshenvIsAZshProgram is the same check for the .zshenv, which
// the bootstrap only copies and never parses.
func TestKidoZshenvIsAZshProgram(t *testing.T) {
	zsh, err := exec.LookPath("zsh")
	if err != nil {
		t.Skip("no zsh in PATH")
	}
	cmd := exec.Command(zsh, "-n")
	cmd.Stdin = strings.NewReader(kidoZshenv)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("zsh -n: %v\n%s", err, out)
	}
}

// TestSSHBootstrapCarriesTheIntegration pins both payloads: the embedded
// zsh and bash integrations, base64 of each and nothing else, and
// quotable. The base64 alphabet holds no single quote, which is what
// makes wrapping a payload in one pair of single quotes safe with no
// escaping at all - a payload that ever grew one would end the quoting
// early and hand the remote shell the rest of the file as commands.
func TestSSHBootstrapCarriesTheIntegration(t *testing.T) {
	boot := sshBootstrap()
	cases := []struct {
		name   string
		src    []byte
		marker string
	}{
		{"zsh", shell.ZshIntegration, "kido_osc133_preexec"},
		{"bash", shell.BashIntegration, "kido_osc133_preexec"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			payload := base64.StdEncoding.EncodeToString(c.src)
			if strings.ContainsAny(payload, "'\\") {
				t.Fatalf("the encoded payload is not safe inside single quotes: %q", payload)
			}
			if !strings.Contains(boot, "'"+payload+"'") {
				t.Error("the bootstrap does not carry the embedded integration, single-quoted")
			}
			decoded, err := base64.StdEncoding.DecodeString(payload)
			if err != nil {
				t.Fatalf("decoding the payload: %v", err)
			}
			if !bytes.Equal(decoded, c.src) {
				t.Errorf("the payload does not decode back to shell/%s/integration.%s", c.name, c.name)
			}
			if !bytes.Contains(c.src, []byte(c.marker)) {
				t.Errorf("the embedded integration is not kido's %s integration", c.name)
			}
		})
	}
}

// fakeShell writes a script that stands in for a remote login shell and
// reports what the bootstrap did to it: its arguments, the ZDOTDIR or ENV
// it was handed, and what is in that directory. name is its basename,
// which is the only thing the bootstrap's shell detection reads.
func fakeShell(t *testing.T, name string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, name)
	// `$shell -l -c :` is the bootstrap's probe for whether this shell
	// takes -l, and answering it must print nothing.
	body := `#!/bin/sh
[ "$2" = "-c" ] && exit 0
echo "args=$*"
echo "ZDOTDIR=${ZDOTDIR-<unset>}"
[ -n "$ZDOTDIR" ] && ls -a "$ZDOTDIR"
echo "ENV=${ENV-<unset>}"
[ -n "$ENV" ] && ls -a "$(dirname "$ENV")"
exit 0
`
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// envFrom reads the ENV line the stand-in shell printed.
func envFrom(t *testing.T, out string) string {
	t.Helper()
	m := regexp.MustCompile(`(?m)^ENV=(.*)$`).FindStringSubmatch(out)
	if m == nil {
		t.Fatalf("output %q names no ENV", out)
	}
	return m[1]
}

// TestBootstrapPrimesBash is TestBootstrapPrimesZsh's counterpart: a
// stand-in login shell named bash is exec'd with --login --posix and an
// ENV pointing at a throwaway directory holding both env.bash and the
// decoded integration.
func TestBootstrapPrimesBash(t *testing.T) {
	out, tmpdir := runBootstrap(t, t.TempDir(), fakeShell(t, "bash"))
	if !strings.Contains(out, "args=--login --posix") {
		t.Errorf("output %q, want the login shell exec'd with --login --posix", out)
	}
	if envFrom(t, out) == "<unset>" {
		t.Fatalf("output %q names no ENV", out)
	}
	if !strings.Contains(out, "env.bash") || !strings.Contains(out, "integration.bash") {
		t.Errorf("output %q, want the ENV directory to hold env.bash and integration.bash", out)
	}
	// As in TestBootstrapPrimesZsh: the stand-in shell never reads ENV, so
	// nothing removed the directory and the trap could not run either,
	// because the bootstrap exec'd.
	if got := leftBehind(t, tmpdir); len(got) != 1 {
		t.Errorf("temporary directories = %q, want the one this run made", got)
	}
}

// runBootstrap runs the bootstrap under a real /bin/sh, as the remote's
// login shell would run it, with home as $HOME and shell as $SHELL. It
// returns everything the run printed and the TMPDIR the bootstrap's
// `mktemp -d` had to work in, so a caller can see what was left behind.
func runBootstrap(t *testing.T, home, shell string, env ...string) (out, tmpdir string) {
	t.Helper()
	tmpdir = filepath.Join(t.TempDir(), "tmp")
	if err := os.MkdirAll(tmpdir, 0o755); err != nil {
		t.Fatal(err)
	}
	cmd := noTTY(exec.Command("/bin/sh", "-c", sshBootstrap()))
	cmd.Env = append([]string{
		"PATH=" + os.Getenv("PATH"),
		"HOME=" + home,
		"SHELL=" + shell,
		"TMPDIR=" + tmpdir,
	}, env...)
	b, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("bootstrap: %v\n%s", err, b)
	}
	return string(b), tmpdir
}

// zshHome is a home directory holding one .zshrc: a remote that has zsh
// dotfiles but nothing of kido's, which is the host `kido ssh` exists
// for. rc is appended to it.
func zshHome(t *testing.T, rc string) string {
	t.Helper()
	home := t.TempDir()
	body := "PS1='remote%% '\n" + rc
	if err := os.WriteFile(filepath.Join(home, ".zshrc"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return home
}

// leftBehind names what the bootstrap left in the directory its temporary
// one was made in. Nothing kido sends may outlive the session.
func leftBehind(t *testing.T, tmpdir string) []string {
	t.Helper()
	entries, err := os.ReadDir(tmpdir)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, e := range entries {
		names = append(names, e.Name())
	}
	return names
}

// TestBootstrapPrimesZsh runs the bootstrap against a stand-in login
// shell named zsh and reads back what it was handed: a ZDOTDIR that is
// not the home directory, holding the .zshenv and the integration.
func TestBootstrapPrimesZsh(t *testing.T) {
	home := zshHome(t, "")
	out, tmpdir := runBootstrap(t, home, fakeShell(t, "zsh"))
	if !strings.Contains(out, "args=-l") {
		t.Errorf("output %q, want the login shell exec'd with -l", out)
	}
	zdotdir := zdotdirFrom(t, out)
	if zdotdir == home {
		t.Errorf("ZDOTDIR = %q, the remote home directory: kido must never write there", zdotdir)
	}
	if !strings.Contains(out, ".zshenv") || !strings.Contains(out, "integration.zsh") {
		t.Errorf("output %q, want the ZDOTDIR to hold .zshenv and integration.zsh", out)
	}
	// The stand-in shell is not zsh, so nothing read the .zshenv that
	// would have removed the directory; the trap could not run either,
	// because the bootstrap exec'd. That the directory is still here is
	// what makes the pristine test below - where a real zsh does read it -
	// the only evidence that the cleanup happens at all.
	if got := leftBehind(t, tmpdir); len(got) != 1 {
		t.Errorf("temporary directories = %q, want the one this run made", got)
	}
}

// zdotdirFrom reads the ZDOTDIR line the stand-in shell printed.
func zdotdirFrom(t *testing.T, out string) string {
	t.Helper()
	m := regexp.MustCompile(`(?m)^ZDOTDIR=(.*)$`).FindStringSubmatch(out)
	if m == nil {
		t.Fatalf("output %q names no ZDOTDIR", out)
	}
	return m[1]
}

// TestBootstrapRedirectsAnExistingZDOTDIR pins the first half of keeping
// a remote whose dotfiles are not in $HOME working: the swap happens
// there too, rather than the bootstrap deciding this login has no zsh
// dotfiles because $HOME holds none. The second half - that the session
// still loads them - is TestSSHPrimesAZshWithItsOwnZDOTDIR, which needs a
// real zsh to read the .zshenv that restores it.
func TestBootstrapRedirectsAnExistingZDOTDIR(t *testing.T) {
	dots := zshHome(t, "")
	out, _ := runBootstrap(t, t.TempDir(), fakeShell(t, "zsh"), "ZDOTDIR="+dots)
	switch got := zdotdirFrom(t, out); got {
	case dots:
		t.Error("ZDOTDIR was left pointing at the user's own dotfiles, so nothing is primed")
	case "<unset>":
		t.Error("ZDOTDIR was cleared; the session would lose the dotfiles it was started with")
	}
}

// TestBootstrapFallsBackToAPlainShell pins the degrade paths: each of
// these must exec the login shell with nothing changed, and leave no
// temporary directory behind.
func TestBootstrapFallsBackToAPlainShell(t *testing.T) {
	t.Run("a login shell kido does not know", func(t *testing.T) {
		out, tmpdir := runBootstrap(t, zshHome(t, ""), fakeShell(t, "ksh"))
		if got := zdotdirFrom(t, out); got != "<unset>" {
			t.Errorf("ZDOTDIR = %q, want a ksh session left alone", got)
		}
		if got := leftBehind(t, tmpdir); len(got) != 0 {
			t.Errorf("left %q behind on the remote", got)
		}
	})

	// kitty's own care, kept: a zsh user with no dotfiles at all is about
	// to be offered zsh-newuser-install, and a ZDOTDIR pointing at kido's
	// directory would suppress it - quietly changing what the user's first
	// login does.
	t.Run("a zsh with no dotfiles, which has zsh-newuser-install to run", func(t *testing.T) {
		out, tmpdir := runBootstrap(t, t.TempDir(), fakeShell(t, "zsh"))
		if got := zdotdirFrom(t, out); got != "<unset>" {
			t.Errorf("ZDOTDIR = %q, want a first-login zsh left alone", got)
		}
		if got := leftBehind(t, tmpdir); len(got) != 0 {
			t.Errorf("left %q behind on the remote", got)
		}
	})

	t.Run("a remote with no base64", func(t *testing.T) {
		// A PATH holding the stand-in shell and nothing else: no base64,
		// no mktemp, which is the bare remote the bootstrap has to survive.
		shell := fakeShell(t, "zsh")
		tmpdir := filepath.Join(t.TempDir(), "tmp")
		if err := os.MkdirAll(tmpdir, 0o755); err != nil {
			t.Fatal(err)
		}
		cmd := noTTY(exec.Command("/bin/sh", "-c", sshBootstrap()))
		cmd.Env = []string{
			"PATH=" + filepath.Dir(shell),
			"HOME=" + zshHome(t, ""),
			"SHELL=" + shell,
			"TMPDIR=" + tmpdir,
		}
		b, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("bootstrap: %v\n%s", err, b)
		}
		if got := zdotdirFrom(t, string(b)); got != "<unset>" {
			t.Errorf("ZDOTDIR = %q, want a remote with no tools left alone", got)
		}
		if got := leftBehind(t, tmpdir); len(got) != 0 {
			t.Errorf("left %q behind on the remote", got)
		}
	})
}

// TestBootstrapDecodesWithABSDBase64 pins the second decode attempt: a
// remote whose base64 only understands -D must still be primed, not
// quietly demoted to a plain session. The stand-in rejects -d the way
// that base64 does, and delegates -D to the real one.
func TestBootstrapDecodesWithABSDBase64(t *testing.T) {
	real, err := exec.LookPath("base64")
	if err != nil {
		t.Skip("no base64 in PATH")
	}
	shim := t.TempDir()
	body := "#!/bin/sh\n[ \"$1\" = \"-d\" ] && { echo 'invalid option -- d' >&2; exit 1; }\n" +
		"[ \"$1\" = \"-D\" ] && exec " + real + " -d\nexec " + real + " \"$@\"\n"
	if err := os.WriteFile(filepath.Join(shim, "base64"), []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}

	shell := fakeShell(t, "zsh")
	tmpdir := filepath.Join(t.TempDir(), "tmp")
	if err := os.MkdirAll(tmpdir, 0o755); err != nil {
		t.Fatal(err)
	}
	cmd := noTTY(exec.Command("/bin/sh", "-c", sshBootstrap()))
	cmd.Env = []string{
		"PATH=" + shim + ":" + os.Getenv("PATH"),
		"HOME=" + zshHome(t, ""), "SHELL=" + shell, "TMPDIR=" + tmpdir,
	}
	b, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("bootstrap: %v\n%s", err, b)
	}
	if got := zdotdirFrom(t, string(b)); got == "<unset>" {
		t.Errorf("a remote with a BSD base64 was left unprimed; output is %q", b)
	}
	if !strings.Contains(string(b), "integration.zsh") {
		t.Errorf("the integration was not decoded; output is %q", b)
	}
}

// interactiveZsh writes a shell named zsh that is a real zsh forced
// interactive, so a test can drive it down a pipe. $SHELL is what the
// bootstrap execs, and zsh is only interactive on a tty; the pipe stands
// in for the pty ssh -t provides, and -i for what that pty would have
// made zsh decide on its own.
func interactiveZsh(t *testing.T) string {
	t.Helper()
	real, err := exec.LookPath("zsh")
	if err != nil {
		t.Skip("no zsh in PATH")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "zsh")
	body := "#!/bin/sh\n[ \"$2\" = \"-c\" ] && exit 0\nexec " + real + " -i \"$@\"\n"
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// osc133 matches any of kido's markers in a stream of shell output.
var osc133 = regexp.MustCompile("\x1b\\]133;[ACD]")

// TestSSHPrimesAPristineZsh is the claim `kido ssh` is for, with its
// negative control: a zsh whose dotfiles know nothing about kido reports
// nothing, and the same zsh started through kido's bootstrap reports a
// prompt, a command line and an exit status.
//
// The far side here is this machine rather than another host, and the
// bootstrap is run directly rather than carried by ssh: what ssh
// contributes is a login shell reading dotfiles kido did not write, and
// that is exactly what the pristine HOME is. A remote that already
// sourced kido's integration - the developer's own localhost, most likely
// - could not tell the two halves apart, which is why this test builds
// its own home instead of logging in anywhere.
func TestSSHPrimesAPristineZsh(t *testing.T) {
	shell := interactiveZsh(t)
	home := zshHome(t, "")
	script := "true\nexit\n"

	// The control: the same pristine zsh, started the way ssh would start
	// it with no kido in front of it.
	plain := noTTY(exec.Command(shell, "-l"))
	plain.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=" + home, "SHELL=" + shell}
	plain.Stdin = strings.NewReader(script)
	control, err := plain.CombinedOutput()
	if err != nil {
		t.Fatalf("plain zsh: %v\n%s", err, control)
	}
	if osc133.Match(control) {
		t.Fatalf("the pristine remote already reports OSC 133 without kido; this test would prove nothing\n%q", control)
	}

	tmpdir := filepath.Join(t.TempDir(), "tmp")
	if err := os.MkdirAll(tmpdir, 0o755); err != nil {
		t.Fatal(err)
	}
	primed := noTTY(exec.Command("/bin/sh", "-c", sshBootstrap()))
	primed.Env = []string{
		"PATH=" + os.Getenv("PATH"), "HOME=" + home, "SHELL=" + shell, "TMPDIR=" + tmpdir,
	}
	primed.Stdin = strings.NewReader(script)
	out, err := primed.CombinedOutput()
	if err != nil {
		t.Fatalf("primed zsh: %v\n%s", err, out)
	}
	for _, want := range []string{"\x1b]133;A", "\x1b]133;C;cmdline=true", "\x1b]133;D;0"} {
		if !strings.Contains(string(out), want) {
			t.Errorf("primed output does not contain %q; it is %q", want, out)
		}
	}
	// Nothing persists: the .zshenv removes the directory as it reads it,
	// which is the only cleanup there is once the bootstrap has exec'd.
	if got := leftBehind(t, tmpdir); len(got) != 0 {
		t.Errorf("left %q behind on the remote", got)
	}
	// The user's own dotfiles still ran, from their own directory: a
	// ZDOTDIR kido pointed elsewhere and forgot to restore would be a far
	// worse thing to do to a login than not reporting at all.
	if !strings.Contains(string(out), "remote%") {
		t.Errorf("the pristine .zshrc did not run; output is %q", out)
	}
}

// TestSSHPrimesAZshThatSplitsWords pins the quoting in the .zshenv. The
// integration is eval'd at the first precmd, which is after the remote's
// own rc files have had their say; under SH_WORD_SPLIT an unquoted eval
// rejoins the script's lines with spaces and the remote reports nothing.
func TestSSHPrimesAZshThatSplitsWords(t *testing.T) {
	shell := interactiveZsh(t)
	home := zshHome(t, "setopt SH_WORD_SPLIT\n")
	tmpdir := filepath.Join(t.TempDir(), "tmp")
	if err := os.MkdirAll(tmpdir, 0o755); err != nil {
		t.Fatal(err)
	}
	cmd := noTTY(exec.Command("/bin/sh", "-c", sshBootstrap()))
	cmd.Env = []string{
		"PATH=" + os.Getenv("PATH"), "HOME=" + home, "SHELL=" + shell, "TMPDIR=" + tmpdir,
	}
	cmd.Stdin = strings.NewReader("true\nexit\n")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("primed zsh: %v\n%s", err, out)
	}
	if !strings.Contains(string(out), "\x1b]133;C;cmdline=true") {
		t.Errorf("nothing was primed under SH_WORD_SPLIT; output is %q", out)
	}
}

// TestSSHPrimesAZshWithItsOwnZDOTDIR is the same claim for a remote whose
// dotfiles live outside $HOME: the .zshenv kido puts in front must hand
// ZDOTDIR back before zsh looks for a .zshrc, or the session would lose
// its own dotfiles - which is the one outcome worse than not reporting.
func TestSSHPrimesAZshWithItsOwnZDOTDIR(t *testing.T) {
	shell := interactiveZsh(t)
	dots := zshHome(t, "")
	tmpdir := filepath.Join(t.TempDir(), "tmp")
	if err := os.MkdirAll(tmpdir, 0o755); err != nil {
		t.Fatal(err)
	}
	cmd := noTTY(exec.Command("/bin/sh", "-c", sshBootstrap()))
	cmd.Env = []string{
		"PATH=" + os.Getenv("PATH"), "HOME=" + t.TempDir(), "SHELL=" + shell,
		"TMPDIR=" + tmpdir, "ZDOTDIR=" + dots,
	}
	cmd.Stdin = strings.NewReader("true\nexit\n")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("primed zsh: %v\n%s", err, out)
	}
	if !osc133.Match(out) {
		t.Errorf("nothing was primed; output is %q", out)
	}
	if !strings.Contains(string(out), "remote%") {
		t.Errorf("the session lost its own ZDOTDIR: %q did not run its .zshrc\n%s", dots, out)
	}
	if got := leftBehind(t, tmpdir); len(got) != 0 {
		t.Errorf("left %q behind on the remote", got)
	}
}

// interactiveBash writes a shell named bash that is a real bash forced
// interactive, so a test can drive it down a pipe, the same trick
// interactiveZsh plays. Order matters here in a way it does not for zsh:
// bash's option parser treats a long option like --login as invalid once
// it has seen a short one, so -i has to come after "$@", not before it.
// Skips when the bash on PATH cannot run the primed integration at all -
// the version floor itself is TestBootstrapFallsBackForOldBash's claim,
// not this helper's.
func interactiveBash(t *testing.T) string {
	t.Helper()
	real, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("no bash in PATH")
	}
	if !bashAtLeast44(real) {
		t.Skip("bash on PATH is older than 4.4")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "bash")
	body := "#!/bin/sh\nexec " + real + " \"$@\" -i\n"
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// bashAtLeast44 reports whether the bash at path is new enough for PS0,
// by asking it to evaluate the same test kidoBashEnv runs on the remote.
func bashAtLeast44(path string) bool {
	err := exec.Command(path, "-c",
		`[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }`).Run()
	return err == nil
}

// TestSSHPrimesAPristineBash is TestSSHPrimesAPristineZsh's counterpart,
// with the same negative control: a bash whose dotfiles know nothing
// about kido reports nothing on its own, and the same bash started
// through kido's bootstrap reports a prompt, a command line and an exit
// status, with its own .bash_profile still the one that set the prompt.
func TestSSHPrimesAPristineBash(t *testing.T) {
	shell := interactiveBash(t)
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, ".bash_profile"), []byte("PS1='remote$ '\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	script := "true\nexit\n"

	// The control: the same pristine bash, started the way ssh would start
	// it with no kido in front of it.
	plain := noTTY(exec.Command(shell, "--login"))
	plain.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=" + home, "SHELL=" + shell, "TERM=dumb"}
	plain.Stdin = strings.NewReader(script)
	control, err := plain.CombinedOutput()
	if err != nil {
		t.Fatalf("plain bash: %v\n%s", err, control)
	}
	if osc133.Match(control) {
		t.Fatalf("the pristine remote already reports OSC 133 without kido; this test would prove nothing\n%q", control)
	}

	tmpdir := filepath.Join(t.TempDir(), "tmp")
	if err := os.MkdirAll(tmpdir, 0o755); err != nil {
		t.Fatal(err)
	}
	primed := noTTY(exec.Command("/bin/sh", "-c", sshBootstrap()))
	primed.Env = []string{
		"PATH=" + os.Getenv("PATH"), "HOME=" + home, "SHELL=" + shell, "TMPDIR=" + tmpdir, "TERM=dumb",
	}
	primed.Stdin = strings.NewReader(script)
	out, err := primed.CombinedOutput()
	if err != nil {
		t.Fatalf("primed bash: %v\n%s", err, out)
	}
	for _, want := range []string{"\x1b]133;A", "\x1b]133;C;cmdline=true", "\x1b]133;D;0"} {
		if !strings.Contains(string(out), want) {
			t.Errorf("primed output does not contain %q; it is %q", want, out)
		}
	}
	// Nothing persists: kidoBashEnv removes the directory as it reads it,
	// the same way the .zshenv does for zsh.
	if got := leftBehind(t, tmpdir); len(got) != 0 {
		t.Errorf("left %q behind on the remote", got)
	}
	// The user's own dotfiles still ran, from their own $HOME: an ENV kido
	// pointed elsewhere and forgot to restore would be a far worse thing to
	// do to a login than not reporting at all.
	if !strings.Contains(string(out), "remote$") {
		t.Errorf("the pristine .bash_profile did not run; output is %q", out)
	}
}

// TestSSHPrimesABashSourcesBashrc pins that both of a real bash login's
// own files ran: kidoBashEnv sources only /etc/profile and the first of
// .bash_profile, .bash_login, .profile itself, exactly as a login bash
// with no kido in front of it would - so a .bashrc only runs if the
// user's own .bash_profile sources it, which is what this one does.
func TestSSHPrimesABashSourcesBashrc(t *testing.T) {
	shell := interactiveBash(t)
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, ".bash_profile"),
		[]byte("echo KIDO_BASH_PROFILE_RAN\nsource ~/.bashrc\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, ".bashrc"),
		[]byte("echo KIDO_BASH_RC_RAN\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	tmpdir := filepath.Join(t.TempDir(), "tmp")
	if err := os.MkdirAll(tmpdir, 0o755); err != nil {
		t.Fatal(err)
	}
	cmd := noTTY(exec.Command("/bin/sh", "-c", sshBootstrap()))
	cmd.Env = []string{
		"PATH=" + os.Getenv("PATH"), "HOME=" + home, "SHELL=" + shell, "TMPDIR=" + tmpdir, "TERM=dumb",
	}
	cmd.Stdin = strings.NewReader("true\nexit\n")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("primed bash: %v\n%s", err, out)
	}
	for _, want := range []string{"KIDO_BASH_PROFILE_RAN", "KIDO_BASH_RC_RAN"} {
		if !strings.Contains(string(out), want) {
			t.Errorf("output does not contain %q; it is %q", want, out)
		}
	}
	if got := leftBehind(t, tmpdir); len(got) != 0 {
		t.Errorf("left %q behind on the remote", got)
	}
}

// TestSSHPrimesABashWithOnlyAProfile pins the fallback order kidoBashEnv
// gives login files: a remote with a .profile and no .bash_profile or
// .bash_login still gets it, the same order a login bash with no kido in
// front of it uses.
func TestSSHPrimesABashWithOnlyAProfile(t *testing.T) {
	shell := interactiveBash(t)
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, ".profile"),
		[]byte("echo KIDO_DOT_PROFILE_RAN\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	tmpdir := filepath.Join(t.TempDir(), "tmp")
	if err := os.MkdirAll(tmpdir, 0o755); err != nil {
		t.Fatal(err)
	}
	cmd := noTTY(exec.Command("/bin/sh", "-c", sshBootstrap()))
	cmd.Env = []string{
		"PATH=" + os.Getenv("PATH"), "HOME=" + home, "SHELL=" + shell, "TMPDIR=" + tmpdir, "TERM=dumb",
	}
	cmd.Stdin = strings.NewReader("true\nexit\n")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("primed bash: %v\n%s", err, out)
	}
	if !strings.Contains(string(out), "KIDO_DOT_PROFILE_RAN") {
		t.Errorf(".profile did not run with no .bash_profile present; output is %q", out)
	}
	if !osc133.Match(out) {
		t.Errorf("nothing was primed; output is %q", out)
	}
	if got := leftBehind(t, tmpdir); len(got) != 0 {
		t.Errorf("left %q behind on the remote", got)
	}
}

// TestBootstrapFallsBackForOldBash pins the version floor: a login bash
// too old for PS0 (macOS ships 3.2 as /bin/bash) must not be left half
// primed. What that host's own bash actually does is not read $ENV under
// --posix at all, login files included, which happens to reach the same
// place kidoBashEnv's own $BASH_VERSINFO check aims for - the login files
// bash always reads on its own, and no markers - by a different route,
// so this test does not assert on the temporary directory the way its
// siblings do: nothing on this host ever reads kidoBashEnv far enough to
// remove it.
func TestBootstrapFallsBackForOldBash(t *testing.T) {
	const old = "/bin/bash"
	if _, err := os.Stat(old); err != nil {
		t.Skip("no /bin/bash on this host")
	}
	if bashAtLeast44(old) {
		t.Skip("/bin/bash on this host is not old enough to exercise the floor")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "bash")
	if err := os.WriteFile(path, []byte("#!/bin/sh\nexec "+old+" \"$@\" -i\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, ".bash_profile"),
		[]byte("echo KIDO_OLD_BASH_PROFILE_RAN\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	tmpdir := filepath.Join(t.TempDir(), "tmp")
	if err := os.MkdirAll(tmpdir, 0o755); err != nil {
		t.Fatal(err)
	}
	cmd := noTTY(exec.Command("/bin/sh", "-c", sshBootstrap()))
	cmd.Env = []string{
		"PATH=" + os.Getenv("PATH"), "HOME=" + home, "SHELL=" + path, "TMPDIR=" + tmpdir, "TERM=dumb",
	}
	cmd.Stdin = strings.NewReader("true\nexit\n")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("bootstrap: %v\n%s", err, out)
	}
	if osc133.Match(out) {
		t.Errorf("an old bash reported OSC 133; output is %q", out)
	}
	if !strings.Contains(string(out), "KIDO_OLD_BASH_PROFILE_RAN") {
		t.Errorf("the login files did not run; output is %q", out)
	}
}
