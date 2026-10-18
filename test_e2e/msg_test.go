package e2e

import (
	"errors"
	"os/exec"
	"strings"
	"testing"
)

// kidoAs runs kido from the test binary as if typed in pane: TMUX names
// the inner server, so kido sees its panes. stdout and stderr come back
// together, the trailing newline trimmed.
func (h *harness) kidoAs(pane, input string, env []string, args ...string) (string, int) {
	h.t.Helper()
	sock := h.in("display-message", "-p", "#{socket_path}")
	cmd := exec.Command(kidoBin, args...)
	cmd.Env = cleanEnv(append([]string{
		"TMUX=" + sock + ",0,0", "TMUX_PANE=" + pane, "KIDO_STATE_DIR=" + h.stateDir,
	}, env...)...)
	cmd.Stdin = strings.NewReader(input)
	out, err := cmd.CombinedOutput()
	code := 0
	if exit := (*exec.ExitError)(nil); errors.As(err, &exit) {
		code = exit.ExitCode()
	} else if err != nil {
		h.t.Fatalf("kido %v: %v", args, err)
	}
	return strings.TrimSuffix(string(out), "\n"), code
}

// firstPane is the pane a session was created with: the caller in these
// tests.
func (h *harness) firstPane(session string) string {
	h.t.Helper()
	return h.in("display-message", "-p", "-t", session+":", "#{pane_id}")
}

// A pi pane with no @kido_inbox takes a prompt as a paste. A stale inbox
// option is an error, never permission to paste: the message may already
// be lost.
func TestPromptPastesOnlyWithoutAnInbox(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	caller := h.firstPane("alpha")
	pane := h.piPane("alpha", "π - pastee")

	if out, rc := h.kidoAs(caller, "hi claude", nil, "prompt"); rc != 0 {
		t.Fatalf("prompt without an inbox = %d %q", rc, out)
	}
	h.waitPaneText(pane, "got: hi claude")

	stale := staleSocket(t)
	h.setPiOptions(pane, "target", "pastee", stale, "")
	if out, rc := h.kidoAs(caller, "hello", nil, "prompt"); rc != 1 || !strings.Contains(out, "pastee is not accepting messages") {
		t.Errorf("prompt with a stale inbox = %d %q, want exit 1 and not accepting", rc, out)
	}
	if got := h.paneText(pane); strings.Contains(got, "got: hello") {
		t.Errorf("a prompt to a closed inbox was pasted: %q", got)
	}
}

// An option outlives a crash, but kido trusts it only while the pane has an
// OSC 7501 pi root: without one the pane is no agent at all.
func TestAStaleOptionWithoutAPiRootIsNoAgent(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	caller := h.firstPane("alpha")
	pane := h.piPane("alpha", "π - stale")
	h.setPiOptions(pane, "stale", "stale", "", "")
	h.programStatus(pane, "state=clear")
	if out, rc := h.kidoAs(caller, "must-not-arrive", nil, "prompt"); rc != 4 || !strings.Contains(out, "agent not found") {
		t.Errorf("prompt to a stale option with no pi root = %d %q, want exit 4 and agent not found", rc, out)
	}
	if got := h.paneText(pane); strings.Contains(got, "must-not-arrive") {
		t.Errorf("a prompt reached a pane with no pi root: %q", got)
	}
}
