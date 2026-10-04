package e2e

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A kido with no argument at all is the launcher now
// (TestKidoInsideAKidoPaneRefuses), so --interval is passed to keep this a
// standalone.
var pickerArgs = []string{"--interval", "100ms"}

func startPickerNoClient(h *harness, session string) *picker {
	h.t.Helper()
	h.keepDeadPanes()
	pane := h.newWindow(session, "picker", append([]string{"env", "-u", "TMUX_SIDE_CLIENT", kidoBin}, pickerArgs...)...)
	return &picker{h: h, pane: pane}
}

// keepDeadPanes sets remain-on-exit before the pane is made: a refusing
// kido can exit before a second tmux call reaches its pane, and setting
// the option on a gone pane fails with "no such window" (measured on a
// loaded runner).
func (h *harness) keepDeadPanes() {
	h.t.Helper()
	h.in("set-option", "-g", "remain-on-exit", "on")
}

// remain-on-exit replaces a dead pane's screen with its own "Pane is
// dead" message (measured), so the refusal text is read from a
// redirected file instead.
func startPickerNoClientCapturingStderr(h *harness, session string) (p *picker, errFile string) {
	h.t.Helper()
	errFile = filepath.Join(h.dir, "refuse-stderr")
	h.keepDeadPanes()
	pane := h.newWindow(session, "picker", "bash", "-c",
		fmt.Sprintf("env -u TMUX_SIDE_CLIENT %q %s 2>%q", kidoBin,
			strings.Join(pickerArgs, " "), errFile))
	return &picker{h: h, pane: pane}, errFile
}

func (p *picker) waitFailure() {
	p.h.t.Helper()
	p.h.waitFor(func() bool { dead, _ := p.dead(); return dead }, settle,
		func() string { return fmt.Sprintf("the picker to exit (shows %q)", p.rows()) })
	if _, status := p.dead(); status == "0" {
		p.h.t.Fatalf("picker exited 0, want a failure (shows %q)", p.rows())
	}
}

// realClientCount excludes kido's own control connections
// (side-status-command dials one per real client), same filter as
// Tmux.Exec.resolve_client.
func (h *harness) realClientCount() int {
	h.t.Helper()
	out := h.in("list-clients", "-F", "#{client_control_mode}")
	n := 0
	for _, l := range strings.Split(out, "\n") {
		if strings.TrimSpace(l) == "0" {
			n++
		}
	}
	return n
}

func (h *harness) attachSecondClient(session string) string {
	h.t.Helper()
	cmd := fmt.Sprintf("unset TMUX; exec %q -S %q attach-session -t %s",
		tmuxBin, h.inner, session)
	return h.must(h.tmux(h.outer, "new-window", "-d", "-P", "-F", "#{window_id}",
		"-t", "host", "-n", "second", cmd))
}

// DEFECT 2, positive case: one real client attached infers and starts
// normally.
func TestStandaloneInfersSoleClient(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	p := startPickerNoClient(h, "alpha")
	p.waitRow("alpha")
	p.mustBeAlive()
	p.keys("q")
	p.waitExit()
}

// DEFECT 2, negative case: two real clients is genuinely ambiguous, so
// kido keeps its refusal rather than guessing which to jump.
func TestStandaloneRefusesWithTwoClients(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	win := h.attachSecondClient("alpha")
	h.waitFor(func() bool { return h.realClientCount() == 2 }, settle,
		func() string { return fmt.Sprintf("two real clients attached (are %d)", h.realClientCount()) })

	p, errFile := startPickerNoClientCapturingStderr(h, "alpha")
	p.waitFailure()
	stderr, err := os.ReadFile(errFile)
	if err != nil {
		t.Fatalf("read %s: %v", errFile, err)
	}
	if !strings.Contains(string(stderr), "no tmux client") {
		t.Errorf("stderr = %q, want today's refusal message", stderr)
	}

	h.tmux(h.outer, "kill-window", "-t", win)
	// The second client's side-status job exits only once the inner server
	// notices the detach; on a loaded CI runner that can outlive this test,
	// tripping the leak check on a client this test itself attached.
	h.waitFor(func() bool { return len(controlClientPIDs(h.inner)) <= 1 }, settle,
		func() string {
			return fmt.Sprintf("the second client's control connection to close (are %v)", controlClientPIDs(h.inner))
		})
}
