package main

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"kido/internal/hook"
	"kido/shell"
)

// awkwardArgs are arguments a shim must pass through exactly: a space, an
// empty argument, a glob, something that looks like an expansion, and a
// flag. A shim that dropped the quotes around "$@", or globbed, loses one.
var awkwardArgs = []string{"a  b", "", "*", "$HOME", "-x"}

// install is one kido install for the shims to run from: <prefix>/bin
// holding a kido and a kido-tmux that record how they were run, and
// <prefix>/share/kido as scripts/install-share.sh lays it out. The prefix
// has a space in it, because nothing in a shim may depend on its
// location being a single word.
type install struct {
	prefix, bin, share, shims string
}

func newInstall(t *testing.T, root string) install {
	t.Helper()
	in := install{prefix: filepath.Join(root, "my prefix")}
	in.bin = filepath.Join(in.prefix, "bin")
	in.share = filepath.Join(in.prefix, "share", "kido")
	in.shims = filepath.Join(in.share, "bin")
	if err := os.MkdirAll(in.bin, 0o755); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command("../../scripts/install-share.sh", in.share).CombinedOutput(); err != nil {
		t.Fatalf("install-share.sh: %v\n%s", err, out)
	}
	recorder(t, in.bin, "kido")
	recorder(t, in.bin, "kido-tmux")
	return in
}

// recorder writes an executable name into dir that records its own path
// and its arguments, NUL-separated, into $ARGV_OUT, and returns its path.
func recorder(t *testing.T, dir, name string) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, name)
	body := "#!/bin/sh\nprintf '%s\\0' \"$0\" \"$@\" > \"$ARGV_OUT\"\n"
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// runShim runs name the way a shell in a kido pane does, by looking it up
// on path (or by path, when name has a slash), and returns the program that ended up running and its
// arguments. The deadline is what a shim that ran itself would hit.
func runShim(t *testing.T, path string, env []string, name string, args ...string) (string, []string) {
	t.Helper()
	out := filepath.Join(t.TempDir(), "argv")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/bin/sh", append([]string{"-c", `exec "$0" "$@"`, name}, args...)...)
	cmd.Env = append([]string{"PATH=" + path, "ARGV_OUT=" + out, "HOME=" + t.TempDir()}, env...)
	if b, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%s %q: %v\n%s", name, args, err, b)
	}
	b, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("%s %q ran nothing that recorded its arguments: %v", name, args, err)
	}
	argv := strings.Split(strings.TrimSuffix(string(b), "\x00"), "\x00")
	return argv[0], argv[1:]
}

func pathOf(dirs ...string) string { return strings.Join(dirs, ":") + ":/usr/bin:/bin" }

// sameFile reports whether a and b name one file, however each is spelled
// - a shim's paths come out with the `..` it worked them out with.
func sameFile(t *testing.T, a, b string) bool {
	t.Helper()
	fa, err := os.Stat(a)
	if err != nil {
		t.Errorf("%s: %v", a, err)
		return false
	}
	fb, err := os.Stat(b)
	if err != nil {
		t.Errorf("%s: %v", b, err)
		return false
	}
	return os.SameFile(fa, fb)
}

// TestShimsRunWhatTheyStandFor is each shim's contract: the program it
// runs, the arguments kido adds in front, and the user's arguments after
// them exactly as given. The files the pi and claude shims name are
// checked to be there, since a shim naming a file the package does not
// ship fails only when that program starts.
func TestShimsRunWhatTheyStandFor(t *testing.T) {
	root := t.TempDir()
	in := newInstall(t, root)
	real := filepath.Join(root, "real")
	recorder(t, real, "pi")
	recorder(t, real, "claude")
	path := pathOf(in.shims, real)

	t.Run("tmux", func(t *testing.T) {
		prog, args := runShim(t, path, nil, "tmux", awkwardArgs...)
		if !sameFile(t, prog, filepath.Join(in.bin, "kido-tmux")) {
			t.Errorf("tmux ran %s, want the kido-tmux beside kido", prog)
		}
		if !slices.Equal(args, awkwardArgs) {
			t.Errorf("args = %q, want %q", args, awkwardArgs)
		}
	})

	t.Run("ssh", func(t *testing.T) {
		prog, args := runShim(t, path, nil, "ssh", awkwardArgs...)
		if !sameFile(t, prog, filepath.Join(in.bin, "kido")) {
			t.Errorf("ssh ran %s, want the kido beside the share it came from", prog)
		}
		if want := append([]string{"ssh"}, awkwardArgs...); !slices.Equal(args, want) {
			t.Errorf("args = %q, want %q", args, want)
		}
	})

	t.Run("pi", func(t *testing.T) {
		prog, args := runShim(t, path, nil, "pi", awkwardArgs...)
		if prog != filepath.Join(real, "pi") {
			t.Errorf("pi ran %s, want the real pi", prog)
		}
		if len(args) != 4+len(awkwardArgs) || args[0] != "--extension" || args[2] != "--extension" {
			t.Fatalf("args = %q, want two --extension before the user's own", args)
		}
		for i, name := range []string{"kido-status.ts", "kido-agents.ts"} {
			if !sameFile(t, args[2*i+1], filepath.Join(in.share, "pi", name)) {
				t.Errorf("--extension %s, want the shipped %s", args[2*i+1], name)
			}
		}
		if !slices.Equal(args[4:], awkwardArgs) {
			t.Errorf("the user's args = %q, want %q", args[4:], awkwardArgs)
		}
	})

	t.Run("claude", func(t *testing.T) {
		prog, args := runShim(t, path, nil, "claude", awkwardArgs...)
		if prog != filepath.Join(real, "claude") {
			t.Errorf("claude ran %s, want the real claude", prog)
		}
		if len(args) != 2+len(awkwardArgs) || args[0] != "--settings" {
			t.Fatalf("args = %q, want --settings before the user's own", args)
		}
		if !sameFile(t, args[1], filepath.Join(in.share, "claude", "settings.json")) {
			t.Errorf("--settings %s, want the shipped settings.json", args[1])
		}
		if !slices.Equal(args[2:], awkwardArgs) {
			t.Errorf("the user's args = %q, want %q", args[2:], awkwardArgs)
		}
	})
}

// TestPiShimLeavesSubcommandsAlone: pi reads `install`, `list` and the
// rest from its first argument, so a shim that put --extension in front
// of them would turn `pi install x` into a session.
func TestPiShimLeavesSubcommandsAlone(t *testing.T) {
	root := t.TempDir()
	in := newInstall(t, root)
	real := filepath.Join(root, "real")
	recorder(t, real, "pi")
	for _, sub := range []string{"install", "remove", "uninstall", "update", "list", "config", "auth"} {
		_, args := runShim(t, pathOf(in.shims, real), nil, "pi", sub, "x")
		if !slices.Equal(args, []string{sub, "x"}) {
			t.Errorf("pi %s x ran with %q, want it untouched", sub, args)
		}
	}
}

// TestShimFindsTheProgramPastItsOwnDirectory: the real program is the
// first one after the shim's directory on PATH - not one ahead of it, and
// never the shim again. A second kido install ahead of the real one is
// the case that makes "after" matter: its shim is a different file, so a
// rule of "anything but myself" would hand over to it and it back.
func TestShimFindsTheProgramPastItsOwnDirectory(t *testing.T) {
	root := t.TempDir()
	in := newInstall(t, root)
	other := newInstall(t, filepath.Join(root, "other"))
	before := filepath.Join(root, "before")
	after := filepath.Join(root, "after")
	recorder(t, before, "pi")
	recorder(t, after, "pi")

	// Run by path, since a lookup would find the pi ahead of it first.
	shim := filepath.Join(in.shims, "pi")
	if prog, _ := runShim(t, pathOf(before, in.shims, after), nil, shim); prog != filepath.Join(after, "pi") {
		t.Errorf("with a pi before the shim and one after it, ran %s, want the one after", prog)
	}
	if prog, _ := runShim(t, pathOf(in.shims, other.shims, after), nil, "pi"); prog != filepath.Join(after, "pi") {
		t.Errorf("through two installs' shims, ran %s, want the real pi after both", prog)
	}

	// Run by path with its directory nowhere on PATH, the shim takes the
	// first pi that is not itself.
	out := filepath.Join(t.TempDir(), "argv")
	cmd := exec.Command(filepath.Join(in.shims, "pi"))
	cmd.Env = []string{"PATH=" + pathOf(before), "ARGV_OUT=" + out}
	if b, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("pi by path: %v\n%s", err, b)
	}
	if b, _ := os.ReadFile(out); !strings.HasPrefix(string(b), filepath.Join(before, "pi")+"\x00") {
		t.Errorf("pi by path ran %q, want %s", b, filepath.Join(before, "pi"))
	}

	// With nothing past it, the shim says so and fails at once. Running
	// itself would not return at all.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd = exec.CommandContext(ctx, "/bin/sh", "-c", `exec pi`)
	cmd.Env = []string{"PATH=" + in.shims + ":/usr/bin:/bin"}
	b, err := cmd.CombinedOutput()
	if ctx.Err() != nil {
		t.Fatal("pi with no real pi on PATH never returned: the shim is running itself")
	}
	if code := cmd.ProcessState.ExitCode(); code != 127 || !strings.Contains(string(b), "no pi on PATH") {
		t.Errorf("pi with no real pi exited %d saying %q, want 127 and a message naming pi (%v)", code, b, err)
	}
}

// TestTmuxShimResolvesLikeKido is internal/tmux's order, in the shim:
// $KIDO_TMUX, then the kido-tmux beside kido, then a tmux on PATH past the
// shim. A bare-name KIDO_TMUX is looked up past the shim as well, since
// exec would otherwise find the shim itself.
func TestTmuxShimResolvesLikeKido(t *testing.T) {
	root := t.TempDir()
	in := newInstall(t, root)
	real := filepath.Join(root, "real")
	recorder(t, real, "tmux")
	named := recorder(t, filepath.Join(root, "named"), "fork-tmux")
	path := pathOf(in.shims, real)

	if prog, _ := runShim(t, path, []string{"KIDO_TMUX=" + named}, "tmux"); prog != named {
		t.Errorf("with KIDO_TMUX=%s, ran %s", named, prog)
	}
	if prog, _ := runShim(t, pathOf(in.shims, filepath.Dir(named)), []string{"KIDO_TMUX=fork-tmux"}, "tmux"); prog != named {
		t.Errorf("with KIDO_TMUX=fork-tmux, ran %s, want %s", prog, named)
	}
	if prog, _ := runShim(t, path, nil, "tmux"); !sameFile(t, prog, filepath.Join(in.bin, "kido-tmux")) {
		t.Errorf("with a kido-tmux beside kido, ran %s", prog)
	}
	if err := os.Remove(filepath.Join(in.bin, "kido-tmux")); err != nil {
		t.Fatal(err)
	}
	if prog, _ := runShim(t, path, nil, "tmux"); prog != filepath.Join(real, "tmux") {
		t.Errorf("with no kido-tmux, ran %s, want the tmux past the shim", prog)
	}
}

// TestLookPathPast is the shims' rule on kido's side, which `kido ssh`
// uses to find the ssh the ssh shim stands in for.
func TestLookPathPast(t *testing.T) {
	root := t.TempDir()
	in := newInstall(t, root)
	other := newInstall(t, filepath.Join(root, "other"))
	before := recorder(t, filepath.Join(root, "before"), "ssh")
	after := recorder(t, filepath.Join(root, "after"), "ssh")

	cases := []struct {
		name, path, want string
	}{
		{"past its own directory", pathOf(filepath.Dir(before), in.shims, filepath.Dir(after)), after},
		{"past a second install", pathOf(in.shims, other.shims, filepath.Dir(after)), filepath.Join(other.shims, "ssh")},
		{"not on PATH", pathOf(filepath.Dir(before)), before},
		{"spelled with a trailing slash", pathOf(in.shims+"/", filepath.Dir(after)), after},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := lookPathPast("ssh", in.shims, c.path)
			if err != nil || got != c.want {
				t.Errorf("lookPathPast = %q, %v, want %q", got, err, c.want)
			}
		})
	}
	if got, err := lookPathPast("ssh", in.shims, in.shims); err == nil {
		t.Errorf("with only the shim on PATH, found %q, want an error", got)
	}
}

func TestPathWithFirst(t *testing.T) {
	cases := []struct{ path, want string }{
		{"/usr/bin:/bin", "/k:/usr/bin:/bin"},
		{"/usr/bin:/k:/bin", "/k:/usr/bin:/bin"},
		{"/k:/usr/bin:/k", "/k:/usr/bin"},
		{"", "/k"},
	}
	for _, c := range cases {
		if got := pathWithFirst("/k", c.path); got != c.want {
			t.Errorf("pathWithFirst(/k, %q) = %q, want %q", c.path, got, c.want)
		}
	}
}

// TestPathPrependScript runs the prepend in every shell that sources it,
// twice over a PATH that already has the directory in the middle: the
// case a login file's rewrite and a nested shell each produce. The
// directory is the worst a bin directory can be - a space, a quote and a
// pattern character - since the script embeds it.
func TestPathPrependScript(t *testing.T) {
	dir := `/opt/it's a [kido]*/bin`
	start := "/usr/bin:" + dir + ":/bin"
	want := dir + ":/usr/bin:/bin"
	script := pathPrependScript(dir) + pathPrependScript(dir) + `printf '%s' "$PATH"`
	for _, sh := range []string{"sh", "bash", "zsh"} {
		t.Run(sh, func(t *testing.T) {
			bin, err := exec.LookPath(sh)
			if err != nil {
				t.Skipf("no %s", sh)
			}
			cmd := exec.Command(bin, "-c", script)
			cmd.Env = []string{"PATH=" + start}
			out, err := cmd.CombinedOutput()
			if err != nil {
				t.Fatalf("%v\n%s", err, out)
			}
			if string(out) != want {
				t.Errorf("PATH = %q, want %q", out, want)
			}
		})
	}
}

// TestOnlyALocalPrimeMovesPATH is the seam between the two primings: the
// local one carries the bin directory, and what `kido ssh` sends carries
// nothing of it. The far side has no kido and no shims, and a PATH
// starting with a directory that is not there would at best be noise.
func TestOnlyALocalPrimeMovesPATH(t *testing.T) {
	marker := pathPrependScript("/k/bin")
	for _, mode := range []primeMode{primeZsh, primeBash} {
		files := primeFiles(mode, "/k/bin")
		found := false
		for _, body := range files {
			found = found || strings.Contains(string(body), marker)
		}
		if !found {
			t.Errorf("mode %d: the local priming does not move PATH", mode)
		}
		for name, body := range primeFiles(mode, "") {
			if strings.Contains(string(body), "_kido_bin") {
				t.Errorf("mode %d: %s moves PATH with no bin directory given", mode, name)
			}
		}
	}
	// The bootstrap's payloads are the shipped integrations byte for byte
	// (TestSSHBootstrapCarriesTheIntegration), so they are what is checked.
	if strings.Contains(sshBootstrap(), "_kido_bin") ||
		strings.Contains(string(shell.ZshIntegration), "_kido_bin") ||
		strings.Contains(string(shell.BashIntegration), "_kido_bin") {
		t.Error("what kido ssh sends moves PATH")
	}
}

// TestShippedClaudeSettingsAreKidosHooks pins the shipped file to the
// event table: every event kido maps, each running `kido hook`, and only
// SessionEnd waited for.
func TestShippedClaudeSettingsAreKidosHooks(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "claude", "settings.json"))
	if err != nil {
		t.Fatal(err)
	}
	var shipped struct {
		Hooks map[string][]any `json:"hooks"`
	}
	if err := json.Unmarshal(raw, &shipped); err != nil {
		t.Fatal(err)
	}
	hooks := shipped.Hooks
	var events []string
	for event, list := range hooks {
		events = append(events, event)
		b, _ := json.Marshal(list)
		var entries []struct {
			Hooks []struct {
				Type, Command string
				Async         bool
			}
		}
		if err := json.Unmarshal(b, &entries); err != nil || len(entries) != 1 || len(entries[0].Hooks) != 1 {
			t.Errorf("%s: %s, want one entry with one hook", event, b)
			continue
		}
		h := entries[0].Hooks[0]
		if h.Type != "command" || h.Command != "kido hook" || h.Async != (event != "SessionEnd") {
			t.Errorf("%s: %+v", event, h)
		}
	}
	slices.Sort(events)
	if !slices.Equal(events, hook.Events()) {
		t.Errorf("events = %q, want hook.Events() = %q", events, hook.Events())
	}
}
