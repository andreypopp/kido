package e2e

import (
	"fmt"
	"regexp"
	"strconv"
	"testing"
)

func TestSubagentRowShowsElapsedUnlessActivity(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	runID, windowID := h.recordedRun("elapsed-agent", "--title", "elapsed-agent")
	pane := h.in("list-panes", "-t", windowID, "-F", "#{pane_id}")
	f := h.startFeed("alpha")
	elapsed := regexp.MustCompile(`elapsed-agent (\d+)s$`)
	seconds := func() int {
		if m := elapsed.FindStringSubmatch(h.rowFor("elapsed-agent")); m != nil {
			n, _ := strconv.Atoi(m[1])
			return n
		}
		return -1
	}
	first := -1
	h.waitFor(func() bool { first = seconds(); return first >= 1 }, settle,
		func() string { return fmt.Sprintf("subagent elapsed seconds, row %q", h.rowFor("elapsed-agent")) })
	h.waitFor(func() bool { return seconds() > first }, settle,
		func() string {
			return fmt.Sprintf("subagent time beyond %ds, row %q", first, h.rowFor("elapsed-agent"))
		})
	started := f.waitLast(func(s feedSnapshot) bool {
		if len(s.Sessions) == 0 {
			return false
		}
		for _, r := range feedItems(s.Sessions[0].Nodes) {
			if r.Pane != nil && *r.Pane == pane {
				return r.Started != nil && len(r.Tail) == 0
			}
		}
		return false
	}, "subagent start time")
	var start float64
	for _, r := range feedItems(started.Sessions[0].Nodes) {
		if r.Pane != nil && *r.Pane == pane {
			start = *r.Started
		}
	}
	for _, activity := range []string{"checking tests", ""} {
		if out, rc := h.kidoAs(pane, "", nil, "tool", "set_status", "--", activity); rc != 0 {
			t.Fatalf("set_status: rc=%d: %s", rc, out)
		}
		h.waitFor(func() bool {
			if activity == "" {
				return seconds() >= first
			}
			return h.rowFor("elapsed-agent") == "└ elapsed-agent "+activity
		}, settle, func() string { return fmt.Sprintf("activity %q, row %q", activity, h.rowFor("elapsed-agent")) })
		f.waitLast(func(s feedSnapshot) bool {
			for _, r := range feedItems(s.Sessions[0].Nodes) {
				if r.Pane != nil && *r.Pane == pane {
					if activity == "" {
						return r.Started != nil && *r.Started == start && len(r.Tail) == 0
					}
					return r.Started != nil && *r.Started == start && len(r.Tail) == 1 && r.Tail[0].Text == activity
				}
			}
			return false
		}, "subagent caption after set_status")
	}
	h.runKido("alpha", "end-agent.out", "run-outcome", "--result", "completed", "--", runID)
	h.in("select-window", "-t", windowID)
	h.killPane(pane)
	h.waitFor(func() bool { return h.rowFor("elapsed-agent") == "└✓elapsed-agent completed" }, settle,
		func() string {
			return fmt.Sprintf("ended subagent %s outcome, row %q", runID, h.rowFor("elapsed-agent"))
		})
}
