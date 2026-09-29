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
// path fails fast on "must run inside tmux" rather than hanging or
// touching a real tmux server.
func runDispatchTest(t *testing.T, args ...string) (stderr string, code int) {
	t.Helper()
	return runDispatchEnv(t, nil, args...)
}

func runDispatchEnv(t *testing.T, env []string, args ...string) (stderr string, code int) {
	t.Helper()
	bin := dispatchTestBin(t)
	cmd := exec.Command(bin, args...)
	cmd.Env = append([]string{"PATH=" + os.Getenv("PATH")}, env...)
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

// TestUnknownSubcommandNamesTheRealOnes: an unrecognised subcommand must
// name itself, not fall through to the interactive UI's misleading
// "must run inside tmux".
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

// TestUnknownSubcommandSuggestsNearMiss covers a genuine typo: an old
// command name, typed by hand or by something that remembers it, before
// it grew a suffix.
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
// treated as an unknown subcommand.
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

// TestBareIsTheLauncher pins both halves of what plain `kido` means:
// inside a tmux it refuses, but the side column - a bare `kido` too,
// told apart by $TMUX_SIDE_CLIENT - must still reach the UI.
func TestBareIsTheLauncher(t *testing.T) {
	t.Run("inside tmux it refuses", func(t *testing.T) {
		stderr, code := runDispatchEnv(t, []string{"TMUX=/tmp/tmux-501/kido,1234,0"})
		if code != 1 {
			t.Fatalf("exit code = %d, want 1 (stderr: %s)", code, stderr)
		}
		if !strings.Contains(stderr, "plain terminal") {
			t.Errorf("stderr = %q, want the launcher's refusal", stderr)
		}
	})

	t.Run("the side column still reaches the UI", func(t *testing.T) {
		stderr, code := runDispatchEnv(t, []string{"TMUX_SIDE_CLIENT=/dev/ttys001"})
		if code != 1 {
			t.Fatalf("exit code = %d, want 1 (stderr: %s)", code, stderr)
		}
		if !strings.Contains(stderr, "must run inside tmux") {
			t.Errorf("stderr = %q, want the UI's own tmux-required error", stderr)
		}
	})
}

// TestKnownSubcommandsDispatch checks that every name in subcommands is
// still routed to its handler rather than unknownSubcommand.
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

func TestSuggestSubcommand(t *testing.T) {
	cases := []struct {
		name string
		want string
	}{
		{"agents", "list_agents"},
		{"message", "message_agent"},
		{"spawn", "spawn_subagent"},
		{"stop", "stop_subagent"},
		{"interrupt", "interrupt_subagent"},
		{"run-outcomes", "run-outcome"},
		{"bogus-command", ""},
	}
	for _, c := range cases {
		if got := suggestSubcommand(c.name); got != c.want {
			t.Errorf("suggestSubcommand(%q) = %q, want %q", c.name, got, c.want)
		}
	}
}
