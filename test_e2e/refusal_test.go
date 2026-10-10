package e2e

import (
	"errors"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"testing"
)

// Refusals bin/main.ml words and exits on itself, before any tmux server is
// asked: the stderr text and exit code are the contract, not the library's
// result.
func TestCommandLineRefusals(t *testing.T) {
	t.Parallel()
	state := serverDir(t)
	for _, c := range []struct {
		args   []string
		stdin  string
		stderr string
		code   int
	}{
		{[]string{"prompt"}, "\n", "no prompt given", 1},
		{[]string{"tool", "message_agent", "anyone"}, "", "no message given", 1},
		{[]string{"tool", "message_agent", "anyone"}, "\n", "no message given", 1},
		{[]string{"runs", "run-a", "extra"}, "", "kido runs: unknown argument \"extra\"\nusage: kido runs [--json] [<run-id>]", 1},
		{[]string{"runs", "no-such-run"}, "", `kido runs: run "no-such-run": no such run`, 1},
		{[]string{"async-run"}, "", "kido async-run: --run-id is required (or $KIDO_AGENT_RUN_ID)\nusage: kido async-run [--run-id ID]", 1},
		{[]string{"tool", "async_bash"}, "", "kido tool async_bash: no command given\nusage: kido tool async_bash [--name NAME] [--stream] -- COMMAND [ARG...]", 1},
		{[]string{"tool", "spawn_subagent", "--name", "kid"}, "", "kido tool spawn_subagent: --parent-pid and --parent-session are required (or --no-parent for a child owned by nobody)\n" +
			"usage: kido tool spawn_subagent --parent-pid PID --parent-session ID --name NAME --task-file FILE|- [--fork SESSION_ID] [--model M] [--tools T,...] [--keep-alive] [-- COMMAND...]\n" +
			"   or: kido tool spawn_subagent --no-parent --name NAME --task-file FILE|- [--model M] [--tools T,...] [--keep-alive] [-- COMMAND...]\n" +
			"   or: kido tool spawn_subagent --resume RUN_ID [--parent-pid PID --parent-session ID | --no-parent] [--keep-alive] [-- COMMAND...]", 1},
	} {
		cmd := exec.Command(kidoBin, c.args...)
		cmd.Env = cleanEnv("KIDO_STATE_DIR="+state, "TMUX_PANE=%1")
		cmd.Stdin = strings.NewReader(c.stdin)
		var stderr strings.Builder
		cmd.Stderr = &stderr
		out, err := cmd.Output()
		code := 0
		if exit := (*exec.ExitError)(nil); errors.As(err, &exit) {
			code = exit.ExitCode()
		} else if err != nil {
			t.Fatalf("kido %v: %v", c.args, err)
		}
		if got := strings.TrimSuffix(stderr.String(), "\n"); got != c.stderr || code != c.code || len(out) != 0 {
			t.Errorf("kido %v: exit %d, stderr %q, stdout %q; want exit %d, stderr %q, no stdout",
				c.args, code, got, out, c.code, c.stderr)
		}
	}
}

// Refusals cmdliner words: its layout wraps and styles with the terminal,
// so only the line naming the fault is pinned, with the exit code.
func TestCmdlinerRefusals(t *testing.T) {
	t.Parallel()
	state := serverDir(t)
	for _, c := range []struct {
		args   []string
		stderr string
	}{
		{[]string{"run-outcome", "--result", "died", "run-a"}, "kido: option '--result': invalid value 'died', expected either 'completed' or"},
		{[]string{"async-run", "--run-id", "run-a", "make"}, "kido: too many arguments, don't know what to do with 'make'"},
	} {
		cmd := exec.Command(kidoBin, c.args...)
		cmd.Env = cleanEnv("KIDO_STATE_DIR="+state, "TERM=dumb")
		var stderr strings.Builder
		cmd.Stderr = &stderr
		out, err := cmd.Output()
		code := 0
		if exit := (*exec.ExitError)(nil); errors.As(err, &exit) {
			code = exit.ExitCode()
		} else if err != nil {
			t.Fatalf("kido %v: %v", c.args, err)
		}
		if !strings.Contains(stderr.String(), c.stderr) || code != 1 || len(out) != 0 {
			t.Errorf("kido %v: exit %d, stderr %q, stdout %q; want exit 1, stderr holding %q, no stdout",
				c.args, code, stderr.String(), out, c.stderr)
		}
	}
}

// A reader that stops early (`kido runs | head -1`) ends kido the way it
// ends any other program: by SIGPIPE, with nothing on stderr.
func TestClosedStdoutEndsQuietly(t *testing.T) {
	t.Parallel()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	r.Close()
	cmd := exec.Command(kidoBin, "runs")
	cmd.Env = cleanEnv("KIDO_STATE_DIR=" + serverDir(t))
	cmd.Stdout = w
	var stderr strings.Builder
	cmd.Stderr = &stderr
	err = cmd.Run()
	w.Close()
	ws, _ := cmd.ProcessState.Sys().(syscall.WaitStatus)
	if !ws.Signaled() || ws.Signal() != syscall.SIGPIPE || stderr.Len() != 0 {
		t.Errorf("kido runs into a closed pipe: %v, stderr %q; want killed by SIGPIPE, no stderr", err, stderr.String())
	}
}
