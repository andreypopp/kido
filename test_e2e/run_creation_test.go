package e2e

import (
	"fmt"
	"testing"
)

// A run's window carries @kido_run and remain-on-exit from the moment it
// exists: the window-linked hook, which runs after the creating command
// list and before another client can supply a separate mark, sees them.
func TestRunMarkedAtWindowCreation(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	caller := h.firstPane("alpha")
	parent := h.firstPane("alpha")
	h.liveParent("alpha", "p")
	h.in("set-hook", "-t", "alpha", "window-linked", "set-option -gF @creation '#{pane_id}:#{@kido_run}:#{remain-on-exit}'")
	for _, name := range []string{"created-agent", "created-bash"} {
		decoy := h.newWindow("alpha", "decoy-"+name, "sleep", "300")
		var r startedRun
		if name == "created-agent" {
			r = h.startRun(caller, "run-child", parent, "--name", name, "--", "sleep", "300")
		} else {
			r = h.startRun(caller, "run", "--name", name, "--", "sleep", "300")
		}
		if got, want := h.in("show-options", "-gv", "@creation"), fmt.Sprintf("%s:%s:on", r.paneID(), r.ID); got != want {
			t.Errorf("%s: window-linked observed %q, want %q", name, got, want)
		}
		if got := h.in("display-message", "-p", "-t", decoy, "#{@kido_run}"); got != "" {
			t.Errorf("%s: pane %s run mark = %q, want empty", name, decoy, got)
		}
		h.killPane(r.paneID())
	}
}
