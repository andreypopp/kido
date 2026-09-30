package e2e

import (
	"errors"
	"os/exec"
	"strings"
	"testing"
)

// Refusals bin/main.ml words and exits on itself, before any tmux server is
// asked: the stderr text and exit code are the contract, not the library's
// result.
func TestCommandLineRefusals(t *testing.T) {
	t.Parallel()
	state := t.TempDir()
	for _, c := range []struct {
		args   []string
		stdin  string
		stderr string
		code   int
	}{
		{[]string{"prompt"}, "\n", "no prompt given", 1},
		{[]string{"message_agent", "anyone"}, "", "no message given", 1},
		{[]string{"runs", "run-a", "extra"}, "", "kido runs: unknown argument \"extra\"\nusage: kido runs [--json] [<run-id>]", 1},
		{[]string{"runs", "no-such-run"}, "", `kido runs: run "no-such-run": no such run`, 1},
		{[]string{"run-outcome", "--result", "died", "run-a"}, "", "kido run-outcome: --result must be \"completed\" or \"failed\"\nusage: kido run-outcome --result completed|failed [--text TEXT] [--unreported] <run-id>", 1},
		{[]string{"hook", "extra"}, "", "usage: kido hook", 0},
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
