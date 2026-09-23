package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// dispatchTestBin is built once (subsequent tests reuse it) rather than
// per test case, since building the whole binary is the only way to
// exercise main()'s os.Exit paths from outside the process.
var (
	dispatchTestBinOnce sync.Once
	dispatchTestBinPath string
	dispatchTestBinErr  error
)

func dispatchTestBin(t *testing.T) string {
	t.Helper()
	dispatchTestBinOnce.Do(func() {
		dir, err := os.MkdirTemp("", "kido-dispatch-test")
		if err != nil {
			dispatchTestBinErr = err
			return
		}
		bin := filepath.Join(dir, "kido")
		out, err := exec.Command("go", "build", "-o", bin, "kido/cmd/kido").CombinedOutput()
		if err != nil {
			dispatchTestBinErr = err
			t.Logf("go build kido: %s", out)
			return
		}
		dispatchTestBinPath = bin
	})
	if dispatchTestBinErr != nil {
		t.Fatalf("build kido: %v", dispatchTestBinErr)
	}
	return dispatchTestBinPath
}

// runDispatchTest runs the built kido binary with args and no environment
// beyond PATH (in particular no TMUX, no TMUX_SIDE_CLIENT), so the UI
// path - reached whenever dispatch does not recognise args[0] as a flag
// error - fails fast on "must run inside tmux" rather than hanging or
// touching a real tmux server.
func runDispatchTest(t *testing.T, args ...string) (stderr string, code int) {
	t.Helper()
	bin := dispatchTestBin(t)
	cmd := exec.Command(bin, args...)
	cmd.Env = []string{"PATH=" + os.Getenv("PATH")}
	var errBuf strings.Builder
	cmd.Stderr = &errBuf
	err := cmd.Run()
	code = 0
	if exitErr, ok := err.(*exec.ExitError); ok {
		code = exitErr.ExitCode()
	} else if err != nil {
		t.Fatalf("run kido %v: %v", args, err)
	}
	return errBuf.String(), code
}

// TestUnknownSubcommandNamesTheRealOnes pins DEFECT 1: an unrecognised
// subcommand used to fall through to the interactive UI, which then
// complained about a missing tmux client - actively misleading, since the
// real problem (a typo, or a name that is not a subcommand) had nothing
// to do with tmux. Reverting the default case in main's switch (or the
// unknownSubcommand call it makes) turns this back into "kido: must run
// inside tmux", which is what this test would show.
func TestUnknownSubcommandNamesTheRealOnes(t *testing.T) {
	stderr, code := runDispatchTest(t, "bogus-command")
	if code != 1 {
		t.Fatalf("exit code = %d, want 1 (stderr: %s)", code, stderr)
	}
	if !strings.Contains(stderr, `unknown subcommand "bogus-command"`) {
		t.Errorf("stderr = %q, want it to name the unrecognised subcommand", stderr)
	}
	if !strings.Contains(stderr, "list_agents") {
		t.Errorf("stderr = %q, want the real subcommands listed", stderr)
	}
	if strings.Contains(stderr, "did you mean") {
		t.Errorf("stderr = %q, bogus-command should get no suggestion", stderr)
	}
}

// TestUnknownSubcommandSuggestsNearMiss used to run `kido list_agents`,
// the defect report's own case: the pi TOOL was list_agents and the
// SUBCOMMAND was `agents`, so the tool's name was a near miss to be
// suggested against. That premise is gone, and the thing worth pinning
// about it moved: that a tool's name and its command's cannot differ at
// all is now TestEveryToolHasASubcommandOfItsName's, mechanically, and a
// suggestion is a poor substitute for a name that is simply right.
// What remains here is the suggestion's own job, genuine typos - of
// which the likeliest is the shape the rename created: the OLD name,
// typed by hand or by something that remembers it, for a command that
// has since grown a suffix.
func TestUnknownSubcommandSuggestsNearMiss(t *testing.T) {
	stderr, code := runDispatchTest(t, "agents")
	if code != 1 {
		t.Fatalf("exit code = %d, want 1 (stderr: %s)", code, stderr)
	}
	if !strings.Contains(stderr, `did you mean "list_agents"?`) {
		t.Errorf("stderr = %q, want a suggestion of list_agents", stderr)
	}
}

// TestLeadingFlagReachesUI pins that `kido -client NAME` (and any other
// leading flag) still reaches the interactive UI path rather than being
// treated as an unknown subcommand. Run with no $TMUX, the UI path fails
// fast on "must run inside tmux"; if the default case in main's switch
// ever stopped special-casing a leading "-", this would instead report
// "unknown subcommand \"-client\"".
func TestLeadingFlagReachesUI(t *testing.T) {
	stderr, code := runDispatchTest(t, "-client", "somebody")
	if code != 1 {
		t.Fatalf("exit code = %d, want 1 (stderr: %s)", code, stderr)
	}
	if !strings.Contains(stderr, "must run inside tmux") {
		t.Errorf("stderr = %q, want the UI's own tmux-required error", stderr)
	}
	if strings.Contains(stderr, "unknown subcommand") {
		t.Errorf("stderr = %q, a leading flag must not be treated as a subcommand", stderr)
	}
}

// TestBareReachesUI pins that plain `kido`, with no arguments, still
// reaches the interactive UI path.
func TestBareReachesUI(t *testing.T) {
	stderr, code := runDispatchTest(t)
	if code != 1 {
		t.Fatalf("exit code = %d, want 1 (stderr: %s)", code, stderr)
	}
	if !strings.Contains(stderr, "must run inside tmux") {
		t.Errorf("stderr = %q, want the UI's own tmux-required error", stderr)
	}
}

// TestKnownSubcommandsDispatch checks that every name in subcommands is
// still routed to its handler rather than unknownSubcommand: each is run
// with no arguments of its own (most then fail their own usage or state
// checks, which is fine - only "unknown subcommand" would mean the switch
// in main stopped recognising it).
func TestKnownSubcommandsDispatch(t *testing.T) {
	for _, cmd := range subcommands {
		cmd := cmd
		t.Run(cmd, func(t *testing.T) {
			stderr, _ := runDispatchTest(t, cmd)
			if strings.Contains(stderr, "unknown subcommand") {
				t.Errorf("stderr = %q, %q should be a recognised subcommand", stderr, cmd)
			}
		})
	}
}

// TestSuggestSubcommand exercises suggestSubcommand directly, in-process,
// for cases beyond the one already covered end-to-end above.
func TestSuggestSubcommand(t *testing.T) {
	cases := []struct {
		name string
		want string
	}{
		// Every former name of a renamed command, which is what a near
		// miss now looks like. Each is shorter than the command it means,
		// the opposite of the shape suggestSubcommand originally matched.
		{"agents", "list_agents"},
		{"message", "message_agent"},
		{"spawn", "spawn_subagent"},
		{"stop", "stop_subagent"},
		{"interrupt", "interrupt_subagent"},
		// And an ordinary typo, still matched the long way round.
		{"run-outcomes", "run-outcome"},
		{"bogus-command", ""},
	}
	for _, c := range cases {
		if got := suggestSubcommand(c.name); got != c.want {
			t.Errorf("suggestSubcommand(%q) = %q, want %q", c.name, got, c.want)
		}
	}
}
