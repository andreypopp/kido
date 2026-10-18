package e2e

import (
	"strings"
	"testing"
)

func TestPiOptionsAndPrompt(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	caller := h.firstPane("alpha")

	t.Run("prompt takes the inbox option", func(t *testing.T) {
		in := startInbox(t, "ok\n")
		pane := h.piPane("alpha", "π - alpha")
		h.setPiOptions(pane, "opt-inbox", "alpha", in.Path, "")
		out, rc := h.kidoAs(caller, "over the socket", nil, "prompt")
		if rc != 0 {
			t.Fatalf("prompt over the inbox option = %d %q", rc, out)
		}
		h.waitInbox(in, "over the socket")
		if got := h.paneText(pane); strings.Contains(got, "over the socket") {
			t.Errorf("the option's inbox prompt was pasted too: %q", got)
		}
		h.programStatus(pane, "state=idle")
	})

	t.Run("options need a pi root", func(t *testing.T) {
		in := startInbox(t, "ok\n")
		pane := h.newWindow("alpha", "", "sh", "-c", "exec sleep 300")
		h.programStatus(pane, "state=idle:app=pi", "π - alpha")
		h.setPiOptions(pane, "opt-session", "Worker", in.Path, "checking")
		h.waitRow("Worker")

		f := h.startFeed("alpha")
		f.waitLast(func(s feedSnapshot) bool {
			r, ok := feedRowFor(s, pane)
			return ok && r.isAgent() && r.Title == "Worker" && r.caption() == "checking"
		}, "the local pi's name and activity from the options")

		h.programStatus(pane, "state=idle")
		f.waitLast(func(s feedSnapshot) bool {
			r, ok := feedRowFor(s, pane)
			return ok && r.isShell() && r.Title != "Worker"
		}, "the stale options to stop making a pi")

		if out, rc := h.kidoAs(caller, "must-not-arrive", nil, "prompt"); rc != 4 || !strings.Contains(out, "agent not found") {
			t.Errorf("prompt with a stale inbox option = %d %q, want exit 4 and agent not found", rc, out)
		}
		if got := in.Received(); len(got) != 0 {
			t.Errorf("a stale inbox option received %q", got)
		}
	})
}
