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

	t.Run("claim writes and unsets the options", func(t *testing.T) {
		pane := h.piPane("alpha", "π - claim")
		in := startInbox(t, "ok\n")
		h.agentStatus("opt-claim", pane, "--name", "Named", "--inbox", in.Path, "--activity", "doing")
		for _, c := range []struct{ key, want string }{
			{"@kido_session", "opt-claim"},
			{"@kido_name", "Named"},
			{"@kido_inbox", in.Path},
			{"@kido_activity", "doing"},
		} {
			if got := h.in("display-message", "-p", "-t", pane, "#{"+c.key+"}"); got != c.want {
				t.Errorf("%s = %q, want %q", c.key, got, c.want)
			}
		}
		if out, rc := h.kidoAs(pane, "", nil, "tool", "set_status", "--", "rewritten"); rc != 0 {
			t.Fatalf("set_status: rc=%d: %s", rc, out)
		}
		if got := h.in("display-message", "-p", "-t", pane, "#{@kido_activity}"); got != "rewritten" {
			t.Errorf("@kido_activity after set_status = %q, want rewritten", got)
		}
		h.agentStatus("opt-claim", pane, "--remove")
		for _, key := range []string{"@kido_session", "@kido_name", "@kido_inbox", "@kido_activity"} {
			if got := h.in("display-message", "-p", "-t", pane, "#{"+key+"}"); got != "" {
				t.Errorf("%s after --remove = %q, want unset", key, got)
			}
		}
		if got := h.in("display-message", "-p", "-t", pane, "#{@kido_run}"); got != "opt-claim" {
			t.Errorf("@kido_run after --remove = %q, want kido's own mark kept", got)
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
