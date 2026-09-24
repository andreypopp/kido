package e2e

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// pickerArgs is a standalone kido with -client omitted, which is what
// puts client inference in charge of the client it drives. The flag it
// does pass only names the default interval: a kido with no argument at
// all is the launcher now (TestKidoInsideAKidoPaneRefuses), so a binding
// careless about -client still has to pass something.
var pickerArgs = []string{"-interval", "100ms"}

// startPickerNoClient runs kido standalone with -client omitted, so
// client inference is what picks the client it drives.
func startPickerNoClient(h *harness, session string) *picker {
	h.t.Helper()
	h.keepDeadPanes()
	pane := h.newWindow(session, "picker", append([]string{"env", "-u", "TMUX_SIDE_CLIENT", kidoBin}, pickerArgs...)...)
	return &picker{h: h, pane: pane}
}

// keepDeadPanes turns remain-on-exit on for every window of the inner
// server, before a pane is made rather than after: a kido that refuses
// exits faster than a second tmux call can reach its pane, and setting
// the option on a pane that has already gone fails with "no such
// window" (measured on a loaded runner).
func (h *harness) keepDeadPanes() {
	h.t.Helper()
	h.in("set-option", "-g", "remain-on-exit", "on")
}

// startPickerNoClientCapturingStderr is startPickerNoClient for the
// refusal case: remain-on-exit replaces a dead pane's screen with its own
// "Pane is dead" message (measured - capture-pane after exit shows that,
// not kido's own stderr), so the refusal text is read from a redirected
// file instead of the pane's screen.
func startPickerNoClientCapturingStderr(h *harness, session string) (p *picker, errFile string) {
	h.t.Helper()
	errFile = filepath.Join(h.dir, "refuse-stderr")
	h.keepDeadPanes()
	pane := h.newWindow(session, "picker", "bash", "-c",
		fmt.Sprintf("env -u TMUX_SIDE_CLIENT %q %s 2>%q", kidoBin,
			strings.Join(pickerArgs, " "), errFile))
	return &picker{h: h, pane: pane}, errFile
}

// waitFailure waits for the picker's pane to exit non-zero, the way
// kido's own refusal (rather than a clean tea.Quit) shows up.
func (p *picker) waitFailure() {
	p.h.t.Helper()
	p.h.waitFor(func() bool { dead, _ := p.dead(); return dead }, settle,
		func() string { return fmt.Sprintf("the picker to exit (shows %q)", p.rows()) })
	if _, status := p.dead(); status == "0" {
		p.h.t.Fatalf("picker exited 0, want a failure (shows %q)", p.rows())
	}
}

// realClientCount is the number of attached clients that are not one of
// kido's own control connections (side-status-command dials one per real
// client), which is what tmux.ResolveClient itself filters by.
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

// attachSecondClient starts a second real pty client attached to
// session, the same way start() attaches the first (a pty-backed tmux
// process in a window of the outer server), and returns its outer window
// id so the caller can close it again.
func (h *harness) attachSecondClient(session string) string {
	h.t.Helper()
	cmd := fmt.Sprintf("unset TMUX; exec %q -L %s attach-session -t %s",
		tmuxBin, h.inner, session)
	return h.must(h.tmux(h.outer, "new-window", "-d", "-P", "-F", "#{window_id}",
		"-t", "host", "-n", "second", cmd))
}

// TestStandaloneInfersSoleClient checks DEFECT 2's positive case: with
// exactly one real client attached to the pane's session, a standalone
// kido started with no -client at all infers it and starts normally,
// rather than refusing.
func TestStandaloneInfersSoleClient(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	p := startPickerNoClient(h, "alpha")
	p.waitRow("alpha")
	p.mustBeAlive()
	p.keys("q")
	p.waitExit()
}

// TestStandaloneRefusesWithTwoClients checks DEFECT 2's negative case:
// two real clients attached to the pane's session is the genuinely
// ambiguous case, so a standalone kido with no -client keeps today's
// refusal and today's message rather than guessing which client to jump.
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
	// The second client's side-status job (its own control-mode client,
	// per client - status.c's "each client runs it") only exits once the
	// inner server has noticed the detach and killed the job in turn; on a
	// loaded CI runner that outlives the test function, and the harness's
	// own leak check (which expects exactly one control client) fires on
	// a client this test itself attached rather than on an actual leak.
	h.waitFor(func() bool { return len(controlClientPIDs(h.inner)) <= 1 }, settle,
		func() string {
			return fmt.Sprintf("the second client's control connection to close (are %v)", controlClientPIDs(h.inner))
		})
}
