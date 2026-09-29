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

	"kido/internal/procs"
	"kido/internal/testutil"
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

// TestParseSSHLettersExcludeValues pins that an option's value is not
// read as more option letters: `-o ProxyCommand=none` carries an N, a T
// and a W among others.
func TestParseSSHLettersExcludeValues(t *testing.T) {
	in := procs.ParseSSH([]string{"-o", "ProxyCommand=none", "-p", "22", "host"})
	if got, want := in.Letters, "op"; got != want {
		t.Errorf("letters = %q, want %q", got, want)
	}
	if !canPrime(in, true) {
		t.Error("an ssh with -o and -p is an ordinary interactive session; kido should prime it")
	}
}

// TestSSHArgsPassesThroughWhatItCannotPrime: every one of these must
// reach ssh exactly as the user spelled it, with no -t and no remote
// command added.
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
// order, then -t, the destination, and the bootstrap as the remote
// command.
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

// TestSSHBootstrapCarriesTheIntegration pins both payloads: base64 of
// each embedded integration, wrapped in single quotes with no escaping,
// which is safe since the base64 alphabet holds no single quote.
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
	// The bootstrap probes with `$shell -c ...` (bash version, for PS0) and
	// `$shell -l -c :` (does -l work at all); a stand-in answering neither
	// is read as unprimable.
	body := `#!/bin/sh
[ "$1" = "-c" ] && { echo 5.2; exit 0; }
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

func TestBootstrapPrimesBash(t *testing.T) {
	out, tmpdir := runBootstrap(t, bootstrapRun{home: t.TempDir(), shell: fakeShell(t, "bash")})
	if !strings.Contains(out, "args=--login --posix") {
		t.Errorf("output %q, want the login shell exec'd with --login --posix", out)
	}
	m := regexp.MustCompile(`(?m)^ENV=(.*)$`).FindStringSubmatch(out)
	if m == nil || m[1] == "<unset>" {
		t.Fatalf("output %q names no ENV", out)
	}
	if !strings.Contains(out, "env.bash") || !strings.Contains(out, "integration.bash") {
		t.Errorf("output %q, want the ENV directory to hold env.bash and integration.bash", out)
	}
	if got := leftBehind(t, tmpdir); len(got) != 1 {
		t.Errorf("temporary directories = %q, want the one this run made", got)
	}
}

type bootstrapRun struct {
	home  string
	shell string
	path  string   // this process's own PATH when empty
	stdin string   // fed to the shell the bootstrap execs
	env   []string // anything further, as NAME=value
}

// runBootstrap runs the bootstrap under a real /bin/sh, as the remote's
// login shell would run it. It returns everything the run printed and
// the TMPDIR the bootstrap's `mktemp -d` had to work in.
//
// TERM is dumb for every caller: readline adds none of its own escape
// sequences for it, which is what makes the reading the same on every
// machine.
func runBootstrap(t *testing.T, r bootstrapRun) (out, tmpdir string) {
	t.Helper()
	tmpdir = filepath.Join(t.TempDir(), "tmp")
	if err := os.MkdirAll(tmpdir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := r.path
	if path == "" {
		path = os.Getenv("PATH")
	}
	cmd := noTTY(exec.Command("/bin/sh", "-c", sshBootstrap()))
	cmd.Env = append([]string{
		"PATH=" + path,
		"HOME=" + r.home,
		"SHELL=" + r.shell,
		"TMPDIR=" + tmpdir,
		"TERM=dumb",
	}, r.env...)
	if r.stdin != "" {
		cmd.Stdin = strings.NewReader(r.stdin)
	}
	b, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("bootstrap: %v\n%s", err, b)
	}
	return string(b), tmpdir
}

func zshHome(t *testing.T, rc string) string {
	t.Helper()
	home := t.TempDir()
	body := "PS1='remote%% '\n" + rc
	if err := os.WriteFile(filepath.Join(home, ".zshrc"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return home
}

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

func TestBootstrapPrimesZsh(t *testing.T) {
	home := zshHome(t, "")
	out, tmpdir := runBootstrap(t, bootstrapRun{home: home, shell: fakeShell(t, "zsh")})
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
	if got := leftBehind(t, tmpdir); len(got) != 1 {
		t.Errorf("temporary directories = %q, want the one this run made", got)
	}
}

func zdotdirFrom(t *testing.T, out string) string {
	t.Helper()
	m := regexp.MustCompile(`(?m)^ZDOTDIR=(.*)$`).FindStringSubmatch(out)
	if m == nil {
		t.Fatalf("output %q names no ZDOTDIR", out)
	}
	return m[1]
}

// TestBootstrapRedirectsAnExistingZDOTDIR: the swap happens even when a
// remote's dotfiles are not in $HOME. The second half - that the session
// still loads them - is TestSSHPrimesAZshWithItsOwnZDOTDIR.
func TestBootstrapRedirectsAnExistingZDOTDIR(t *testing.T) {
	dots := zshHome(t, "")
	out, _ := runBootstrap(t, bootstrapRun{
		home: t.TempDir(), shell: fakeShell(t, "zsh"), env: []string{"ZDOTDIR=" + dots},
	})
	switch got := zdotdirFrom(t, out); got {
	case dots:
		t.Error("ZDOTDIR was left pointing at the user's own dotfiles, so nothing is primed")
	case "<unset>":
		t.Error("ZDOTDIR was cleared; the session would lose the dotfiles it was started with")
	}
}

// TestBootstrapFallsBackToAPlainShell pins the degrade paths: each case
// must exec the login shell with nothing changed, and leave no temporary
// directory behind.
func TestBootstrapFallsBackToAPlainShell(t *testing.T) {
	t.Run("a login shell kido does not know", func(t *testing.T) {
		out, tmpdir := runBootstrap(t, bootstrapRun{home: zshHome(t, ""), shell: fakeShell(t, "ksh")})
		if got := zdotdirFrom(t, out); got != "<unset>" {
			t.Errorf("ZDOTDIR = %q, want a ksh session left alone", got)
		}
		if got := leftBehind(t, tmpdir); len(got) != 0 {
			t.Errorf("left %q behind on the remote", got)
		}
	})

	// A ZDOTDIR pointing at kido's directory would suppress
	// zsh-newuser-install, quietly changing what the user's first login does.
	t.Run("a zsh with no dotfiles, which has zsh-newuser-install to run", func(t *testing.T) {
		out, tmpdir := runBootstrap(t, bootstrapRun{home: t.TempDir(), shell: fakeShell(t, "zsh")})
		if got := zdotdirFrom(t, out); got != "<unset>" {
			t.Errorf("ZDOTDIR = %q, want a first-login zsh left alone", got)
		}
		if got := leftBehind(t, tmpdir); len(got) != 0 {
			t.Errorf("left %q behind on the remote", got)
		}
	})

	t.Run("a remote with no base64", func(t *testing.T) {
		shell := fakeShell(t, "zsh")
		out, tmpdir := runBootstrap(t, bootstrapRun{
			home: zshHome(t, ""), shell: shell, path: filepath.Dir(shell),
		})
		if got := zdotdirFrom(t, out); got != "<unset>" {
			t.Errorf("ZDOTDIR = %q, want a remote with no tools left alone", got)
		}
		if got := leftBehind(t, tmpdir); len(got) != 0 {
			t.Errorf("left %q behind on the remote", got)
		}
	})
}

// TestBootstrapDecodesWithABSDBase64: a remote whose base64 only
// understands -D must still be primed, not quietly demoted to a plain
// session.
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

	out, _ := runBootstrap(t, bootstrapRun{
		home: zshHome(t, ""), shell: fakeShell(t, "zsh"),
		path: shim + ":" + os.Getenv("PATH"),
	})
	if got := zdotdirFrom(t, out); got == "<unset>" {
		t.Errorf("a remote with a BSD base64 was left unprimed; output is %q", out)
	}
	if !strings.Contains(out, "integration.zsh") {
		t.Errorf("the integration was not decoded; output is %q", out)
	}
}

// interactiveZsh writes a shell named zsh that is a real zsh forced
// interactive with -i, standing in for the pty ssh -t would provide.
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

var osc133 = regexp.MustCompile("\x1b\\]133;[ACD]")

// TestSSHPrimesAPristineZsh is the claim `kido ssh` is for, with its
// negative control: a zsh whose dotfiles know nothing about kido reports
// nothing, and the same zsh started through kido's bootstrap reports a
// prompt, a command line and an exit status. Run against a fresh $HOME
// directly rather than a real login, since a remote that already sourced
// kido's integration could not tell the two halves apart.
func TestSSHPrimesAPristineZsh(t *testing.T) {
	shell := interactiveZsh(t)
	home := zshHome(t, "")
	script := "true\nexit\n"

	plain := noTTY(exec.Command(shell, "-l"))
	plain.Env = []string{
		"PATH=" + os.Getenv("PATH"), "HOME=" + home, "SHELL=" + shell, "TERM=dumb",
	}
	plain.Stdin = strings.NewReader(script)
	control, err := plain.CombinedOutput()
	if err != nil {
		t.Fatalf("plain zsh: %v\n%s", err, control)
	}
	if osc133.Match(control) {
		t.Fatalf("the pristine remote already reports OSC 133 without kido; this test would prove nothing\n%q", control)
	}

	out, tmpdir := runBootstrap(t, bootstrapRun{home: home, shell: shell, stdin: script})
	for _, want := range []string{"\x1b]133;A", "\x1b]133;C;cmdline=true", "\x1b]133;D;0"} {
		if !strings.Contains(out, want) {
			t.Errorf("primed output does not contain %q; it is %q", want, out)
		}
	}
	if got := leftBehind(t, tmpdir); len(got) != 0 {
		t.Errorf("left %q behind on the remote", got)
	}
	if !strings.Contains(out, "remote%") {
		t.Errorf("the pristine .zshrc did not run; output is %q", out)
	}
}

// TestSSHPrimesAZshThatSplitsWords pins the quoting in the .zshenv. The
// integration is eval'd at the first precmd, which is after the remote's
// own rc files have had their say; under SH_WORD_SPLIT an unquoted eval
// rejoins the script's lines with spaces and the remote reports nothing.
func TestSSHPrimesAZshThatSplitsWords(t *testing.T) {
	out, _ := runBootstrap(t, bootstrapRun{
		home:  zshHome(t, "setopt SH_WORD_SPLIT\n"),
		shell: interactiveZsh(t),
		stdin: "true\nexit\n",
	})
	if !strings.Contains(out, "\x1b]133;C;cmdline=true") {
		t.Errorf("nothing was primed under SH_WORD_SPLIT; output is %q", out)
	}
}

// TestSSHPrimesAZshWithItsOwnZDOTDIR: the .zshenv kido puts in front
// must hand ZDOTDIR back before zsh looks for a .zshrc, or the session
// would lose its own dotfiles.
func TestSSHPrimesAZshWithItsOwnZDOTDIR(t *testing.T) {
	dots := zshHome(t, "")
	out, tmpdir := runBootstrap(t, bootstrapRun{
		home:  t.TempDir(),
		shell: interactiveZsh(t),
		stdin: "true\nexit\n",
		env:   []string{"ZDOTDIR=" + dots},
	})
	if !osc133.MatchString(out) {
		t.Errorf("nothing was primed; output is %q", out)
	}
	if !strings.Contains(out, "remote%") {
		t.Errorf("the session lost its own ZDOTDIR: %q did not run its .zshrc\n%s", dots, out)
	}
	if got := leftBehind(t, tmpdir); len(got) != 0 {
		t.Errorf("left %q behind on the remote", got)
	}
}

// interactiveBash writes a shell named bash that is a real bash forced
// interactive with -i, placed after "$@": bash's option parser treats a
// long option like --login as invalid once it has seen a short one.
func interactiveBash(t *testing.T) string {
	t.Helper()
	real := testutil.ModernBash(t)
	dir := t.TempDir()
	path := filepath.Join(dir, "bash")
	body := "#!/bin/sh\nexec " + real + " \"$@\" -i\n"
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// TestSSHPrimesAPristineBash is TestSSHPrimesAPristineZsh's counterpart.
func TestSSHPrimesAPristineBash(t *testing.T) {
	shell := interactiveBash(t)
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, ".bash_profile"), []byte("PS1='remote$ '\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	script := "true\nexit\n"

	plain := noTTY(exec.Command(shell, "--login"))
	plain.Env = []string{
		"PATH=" + os.Getenv("PATH"), "HOME=" + home, "SHELL=" + shell, "TERM=dumb",
	}
	plain.Stdin = strings.NewReader(script)
	control, err := plain.CombinedOutput()
	if err != nil {
		t.Fatalf("plain bash: %v\n%s", err, control)
	}
	if osc133.Match(control) {
		t.Fatalf("the pristine remote already reports OSC 133 without kido; this test would prove nothing\n%q", control)
	}

	out, tmpdir := runBootstrap(t, bootstrapRun{home: home, shell: shell, stdin: script})
	for _, want := range []string{"\x1b]133;A", "\x1b]133;C;cmdline=true", "\x1b]133;D;0"} {
		if !strings.Contains(out, want) {
			t.Errorf("primed output does not contain %q; it is %q", want, out)
		}
	}
	if got := leftBehind(t, tmpdir); len(got) != 0 {
		t.Errorf("left %q behind on the remote", got)
	}
	if !strings.Contains(out, "remote$") {
		t.Errorf("the pristine .bash_profile did not run; output is %q", out)
	}
}

// TestSSHPrimesABashSourcesBashrc pins that kidoBashEnv sources only
// /etc/profile and the first of .bash_profile, .bash_login, .profile
// itself, exactly as a login bash with no kido in front of it would - so
// a .bashrc only runs if the user's own .bash_profile sources it.
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
	out, tmpdir := runBootstrap(t, bootstrapRun{
		home: home, shell: shell, stdin: "true\nexit\n",
	})
	for _, want := range []string{"KIDO_BASH_PROFILE_RAN", "KIDO_BASH_RC_RAN"} {
		if !strings.Contains(out, want) {
			t.Errorf("output does not contain %q; it is %q", want, out)
		}
	}
	if got := leftBehind(t, tmpdir); len(got) != 0 {
		t.Errorf("left %q behind on the remote", got)
	}
}

func TestSSHPrimesABashWithOnlyAProfile(t *testing.T) {
	shell := interactiveBash(t)
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, ".profile"),
		[]byte("echo KIDO_DOT_PROFILE_RAN\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	out, tmpdir := runBootstrap(t, bootstrapRun{
		home: home, shell: shell, stdin: "true\nexit\n",
	})
	if !strings.Contains(out, "KIDO_DOT_PROFILE_RAN") {
		t.Errorf(".profile did not run with no .bash_profile present; output is %q", out)
	}
	if !osc133.MatchString(out) {
		t.Errorf("nothing was primed; output is %q", out)
	}
	if got := leftBehind(t, tmpdir); len(got) != 0 {
		t.Errorf("left %q behind on the remote", got)
	}
}

// TestBootstrapFallsBackForOldBash pins the version floor: a login bash
// too old for PS0 (macOS ships 3.2 as /bin/bash) gets its own login files
// and no markers, and is never taken through --posix on the way there.
// Apple's 3.2 does not read $ENV under --posix at all, so the floor must
// be checked in the bootstrap itself, not in that file.
func TestBootstrapFallsBackForOldBash(t *testing.T) {
	const old = "/bin/bash"
	if _, err := os.Stat(old); err != nil {
		t.Skip("no /bin/bash on this host")
	}
	if testutil.BashHasPS0(old) {
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
	out, tmpdir := runBootstrap(t, bootstrapRun{
		home:  home,
		shell: path,
		stdin: "shopt -qo posix; echo KIDO_POSIX_SET=$?\nexit\n",
	})
	if osc133.MatchString(out) {
		t.Errorf("an old bash reported OSC 133; output is %q", out)
	}
	if !strings.Contains(out, "KIDO_OLD_BASH_PROFILE_RAN") {
		t.Errorf("the login files did not run; output is %q", out)
	}
	if !strings.Contains(out, "KIDO_POSIX_SET=1") {
		t.Errorf("the session is in posix mode, which kido put it in and nothing took it out of; output is %q", out)
	}
	if got := leftBehind(t, tmpdir); len(got) != 0 {
		t.Errorf("left %q behind on the remote", got)
	}
}
