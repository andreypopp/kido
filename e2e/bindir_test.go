package e2e

import (
	"context"
	"encoding/json"
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

// Inside a kido pane, tmux, ssh, pi and claude are kido's own: the shims
// in <share>/bin, put first on PATH by the launcher for what the server
// runs and by the primed shell's integration after the user's login
// files. These tests type into a pane of a launched kido, which is the
// only place the second of those happens.

// shellIn runs command in pane through the pane's own shell, with its
// output in a file, and returns that output once the command is done.
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

// primedPane launches kido and returns its first pane once the shell in
// it has reached a prompt, which is after the integration has run.
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

// TestKidoPaneRunsTheShims: `tmux` and `ssh` resolve to the shims in a
// kido pane, and the tmux reached through the shim is one the kido server
// answers - a stock tmux reaching that socket fails on the protocol. The
// server's own run-shell resolves the shim too, because what tmux runs
// without a shell in between has only the server's PATH.
//
// On macOS the pane's login zsh runs path_helper from /etc/zprofile,
// which puts the system directories back in front of an inherited PATH.
// The nested `zsh -l -c` is the control that shows it doing so here:
// same inherited PATH, no integration after it, and the system ssh wins.
// Without that half, a shim first in the pane could as well be the
// launcher's PATH surviving a login that rewrote nothing.
func TestKidoPaneRunsTheShims(t *testing.T) {
	t.Parallel()
	r := newKidoRun(t)
	pane := r.primedPane()
	shims := filepath.Join(shareDir, "bin")

	for _, name := range []string{"tmux", "ssh"} {
		if got := r.shellIn(pane, "command -v "+name); !sameFile(got, filepath.Join(shims, name)) {
			t.Errorf("command -v %s = %q in a kido pane, want the shim in %s", name, got, shims)
		}
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

// fakeRealPrograms puts recording ssh, pi and claude on the PATH of this
// run's shells only, from the user's own rc file - after the login files,
// which is where a user's PATH edits live and the one place macOS
// path_helper does not reorder. Every call writes its arguments,
// NUL-separated, into a file of its own under calls.
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
		body := fmt.Sprintf("#!/bin/sh\nf=$(mktemp %q)\nprintf '%%s\\0' %q \"$@\" >\"$f\"\n",
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

// nextCall waits for the one call the command just typed makes, and
// returns its arguments.
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

// TestShimsReachTheRealPrograms: each shim ends in the real program with
// the user's arguments intact and kido's in front of them. The ssh
// cases cover each of kido ssh's two shapes: passed through as typed (-V,
// and a remote command whose spacing must survive), and primed (an
// interactive login, which gains -t and the bootstrap). A shim that ran
// itself would never reach the recorder, and one that dropped its quotes
// would lose the double space. pi is run with no ~/.pi in this home at
// all, so both extensions arrive through the command line or not at all.
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
	if name, args := run("ssh host"); name != "ssh" || len(args) != 3 ||
		!slices.Equal(args[:2], []string{"-t", "host"}) || !strings.Contains(args[2], "kido_zsh_b64=") {
		t.Errorf("an interactive ssh host reached %s %q, want -t host and the bootstrap", name, args)
	}

	name, args := run("pi 'hello  there'")
	if name != "pi" || len(args) != 5 || args[0] != "--extension" || args[2] != "--extension" || args[4] != "hello  there" {
		t.Fatalf("pi reached %s %q, want two --extension and the message", name, args)
	}
	for i, ext := range []string{"kido-status.ts", "kido-agents.ts"} {
		if !sameFile(args[2*i+1], filepath.Join(shareDir, "pi", ext)) {
			t.Errorf("--extension %s, want the shipped %s", args[2*i+1], ext)
		}
	}

	name, args = run("claude -p hi")
	if name != "claude" || len(args) != 4 || args[0] != "--settings" || !slices.Equal(args[2:], []string{"-p", "hi"}) {
		t.Fatalf("claude reached %s %q, want --settings and the user's own", name, args)
	}
	if !sameFile(args[1], filepath.Join(shareDir, "claude", "settings.json")) {
		t.Errorf("--settings %s, want the shipped settings.json", args[1])
	}
}

// TestPiShimLoadsKidosToolsOnce runs the real pi through the shim, since
// whether two copies of an extension collide is pi's behaviour and not
// something a fake can report. Once with no extensions of its own, and
// once with links in pi's own extensions directory pointing at
// this checkout - a different real path from the shipped copies, which pi
// does not dedupe, so the extensions' own one-copy rule is what keeps the
// tools single and the conflict errors away. Skips where pi is not
// installed, which includes CI.
func TestPiShimLoadsKidosToolsOnce(t *testing.T) {
	t.Parallel()
	if _, err := exec.LookPath("pi"); err != nil {
		t.Skip("no pi on PATH")
	}
	checkout, err := filepath.Abs("../pi")
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	probe := filepath.Join(dir, "probe.ts")
	if err := os.WriteFile(probe, []byte(`import { writeFileSync } from "node:fs";
export default function (pi: any) {
  pi.on("session_start", () => {
    writeFileSync(process.env.KIDO_E2E_PROBE_OUT!, JSON.stringify(pi.getAllTools().map((t: any) => t.name)));
    setTimeout(() => process.exit(0), 50);
  });
}
`), 0o644); err != nil {
		t.Fatal(err)
	}

	for _, links := range []bool{false, true} {
		t.Run(fmt.Sprintf("links=%v", links), func(t *testing.T) {
			agent := filepath.Join(t.TempDir(), "agent")
			exts := filepath.Join(agent, "extensions")
			if err := os.MkdirAll(exts, 0o755); err != nil {
				t.Fatal(err)
			}
			if links {
				for _, name := range []string{"kido-status.ts", "kido-agents.ts"} {
					if err := os.Symlink(filepath.Join(checkout, name), filepath.Join(exts, name)); err != nil {
						t.Fatal(err)
					}
				}
			}
			out := filepath.Join(t.TempDir(), "tools.json")
			ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, filepath.Join(shareDir, "bin", "pi"),
				"--mode", "rpc", "--no-session", "-e", probe)
			cmd.Dir = t.TempDir()
			cmd.Env = cleanEnv("PATH="+filepath.Join(shareDir, "bin")+":"+os.Getenv("PATH"),
				"PI_CODING_AGENT_DIR="+agent, "PI_OFFLINE=1", "KIDO_E2E_PROBE_OUT="+out,
				"KIDO_STATE_DIR="+t.TempDir(), "TMUX=", "TMUX_PANE=")
			log, _ := cmd.CombinedOutput()
			b, err := os.ReadFile(out)
			if err != nil {
				t.Fatalf("pi never started a session: %v\n%s", err, log)
			}
			if strings.Contains(string(log), "conflicts") {
				t.Errorf("pi reported conflicting extensions:\n%s", log)
			}
			var tools []string
			if err := json.Unmarshal(b, &tools); err != nil {
				t.Fatal(err)
			}
			for _, tool := range []string{"list_agents", "spawn_subagent", "notify_parent"} {
				if n := strings.Count(","+strings.Join(tools, ",")+",", ","+tool+","); n != 1 {
					t.Errorf("%s registered %d times, want once: %q", tool, n, tools)
				}
			}
		})
	}
}
