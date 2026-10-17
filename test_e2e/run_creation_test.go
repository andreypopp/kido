package e2e

import (
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunMarkedAtWindowCreation(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.liveParent("alpha", "p")
	h.in("set-hook", "-t", "alpha", "window-linked", "set-option -gF @creation '#{pane_id}:#{@kido_run}:#{remain-on-exit}'")
	for _, kind := range []string{"agent", "bash", "stream"} {
		// The window-linked hook runs from the server queue after the creating
		// command list, before another client can supply a separate mark.
		decoy := h.in("new-window", "-d", "-P", "-F", "#{pane_id}", "-t", "alpha:", "-n", "decoy-"+kind, "sleep 300")
		var pane, run string
		if kind == "agent" {
			out := filepath.Join(h.dir, "spawn-"+kind+".out")
			h.runSpawn(out, filepath.Join(h.dir, "child-"+kind+".env"), "--name", "created-"+kind, "--task-file", h.writeTaskFile("created-"+kind))
			fields := strings.Fields(h.waitFileNonEmpty(out))
			if len(fields) != 3 {
				t.Fatalf("%s: spawn output = %q", kind, fields)
			}
			pane, run = fields[1], fields[2]
		} else {
			var flags []string
			if kind == "stream" {
				flags = []string{"--stream"}
			}
			_, pane, run = h.asyncBashIDs(flags, "created-"+kind, "sleep 300")
		}
		if got, want := h.in("show-options", "-gv", "@creation"), fmt.Sprintf("%s:%s:on", pane, run); got != want {
			t.Errorf("%s: window-linked observed %q, want %q", kind, got, want)
		}
		if got := h.in("display-message", "-p", "-t", decoy, "#{@kido_run}"); got != "" {
			t.Errorf("%s: pane %s run mark = %q, want empty", kind, decoy, got)
		}
	}
}
