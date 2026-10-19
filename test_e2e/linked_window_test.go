package e2e

import (
	"strings"
	"testing"
)

// A run window linked into other sessions has one pane id per session but only
// one pane. Closing it as a pane because the shim counted three occurrences
// destroys every linked session where it is the last window.
func TestRunStopRefusesALinkedRunWindowsLastWindow(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	caller := h.firstPane("alpha")
	r := h.startRun(caller, "run", "--name", "linked-stop", "--", "sleep", "300")
	for _, session := range []string{"linked-a", "linked-b"} {
		h.in("new-session", "-d", "-s", session, "-c", h.dir, "sh", "-c", "exec sleep 300")
		initial := h.in("list-windows", "-t", session, "-F", "#{window_id}")
		h.in("link-window", "-s", r.Window, "-t", session+":")
		h.in("kill-window", "-t", initial)
	}

	out, rc := h.kidoAs(caller, "", nil, "run-stop", r.ID)
	if rc != 1 || !strings.Contains(out, "only pane") {
		t.Fatalf("run-stop of a linked last window = %d %q, want exit 1 and the only-pane refusal", rc, out)
	}
	for _, session := range []string{"linked-a", "linked-b"} {
		if _, err := h.tmux(h.inner, "has-session", "-t", session); err != nil {
			t.Errorf("session %s is gone; run-stop closed its last window: %v", session, err)
		}
	}
}

// The sweep must also refuse a whole-window close when the linked window is
// the last window in any one session, even if another linked session has
// other windows.
func TestReapRefusesALinkedRunWindowsLastWindowInAnySession(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.hideSidebar()
	caller := h.firstPane("alpha")
	r := h.startRun(caller, "run", "--name", "linked-reap", "--", "sh", "-c", "exit 0")
	h.waitFor(func() bool { return h.paneDead(r.paneID()) }, settle, msgf("the linked run's pane to die"))

	h.in("new-session", "-d", "-s", "linked-other", "-c", h.dir, "sh", "-c", "exec sleep 300")
	h.in("link-window", "-s", r.Window, "-t", "linked-other:")
	h.in("new-session", "-d", "-s", "linked-last", "-c", h.dir, "sh", "-c", "exec sleep 300")
	lastInitial := h.in("list-windows", "-t", "linked-last", "-F", "#{window_id}")
	h.in("link-window", "-s", r.Window, "-t", "linked-last:")
	h.in("kill-window", "-t", lastInitial)

	h.stays(linger, func() bool { return h.windowExists(r.Window) }, "the dead linked run to outlive its linger")
	h.runKido("alpha", "reap-linked.out", "reap")
	if !h.windowExists(r.Window) {
		t.Fatalf("window %s is gone; the sweep closed a linked session's last window", r.Window)
	}
	for _, session := range []string{"linked-other", "linked-last"} {
		if _, err := h.tmux(h.inner, "has-session", "-t", session); err != nil {
			t.Errorf("session %s is gone; the sweep closed its last window: %v", session, err)
		}
	}
}
