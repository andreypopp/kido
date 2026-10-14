package e2e

import (
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunMarkedAtWindowCreation(t *testing.T) {
	t.Parallel()
	for _, kind := range []string{"agent", "bash", "stream"} {
		t.Run(kind, func(t *testing.T) {
			h := start(t, "alpha")
			h.liveParent("alpha", "p")
			parent := h.in("display-message", "-p", "-t", "alpha:", "#{pane_id}")
			// The window-linked hook runs from the server queue after the creating
			// command list, before another client can supply a separate mark.
			decoy := h.in("new-window", "-d", "-P", "-F", "#{pane_id}", "-t", "alpha:9", "-n", "created", "sleep 300")
			h.in("set-hook", "-t", "alpha", "window-linked", "set-option -gF @creation '#{pane_id}:#{@kido_run}:#{remain-on-exit}'")
			var pane, run string
			if kind == "agent" {
				out := filepath.Join(h.dir, "spawn.out")
				h.runSpawn(out, filepath.Join(h.dir, "child.env"), "--parent-pid", "1", "--parent-session", "p", "--name", "created", "--task-file", h.writeTaskFile("created"))
				fields := strings.Fields(h.waitFileNonEmpty(out))
				if len(fields) != 3 {
					t.Fatalf("spawn output = %q", fields)
				}
				pane, run = fields[1], fields[2]
			} else {
				var flags []string
				if kind == "stream" {
					flags = []string{"--stream"}
				}
				_, pane, run = h.asyncBashIDs(flags, "created", "sleep 300")
			}
			if got, want := h.in("show-options", "-gv", "@creation"), fmt.Sprintf("%s:%s:on", pane, run); got != want {
				t.Errorf("window-linked observed %q, want %q", got, want)
			}
			for _, untouched := range []string{parent, decoy} {
				if got := h.in("display-message", "-p", "-t", untouched, "#{@kido_run}"); got != "" {
					t.Errorf("pane %s run mark = %q, want empty", untouched, got)
				}
			}
		})
	}
}
