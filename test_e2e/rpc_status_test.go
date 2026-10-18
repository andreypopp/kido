package e2e

import (
	"testing"
)

func TestRpcBareZeroProgressSetsNoStatus(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.newWindow("alpha", "native", nodeBin, "--")
	h.waitPaneCommand(pane, "node")
	f := h.startFeed("alpha")
	h.programStatus(pane, "state=working:progress=1")
	r, _ := feedRowFor(f.waitLast(func(s feedSnapshot) bool {
		r, ok := feedRowFor(s, pane)
		return ok && len(r.ProgramStatus.Records) == 1 && feedValue(r.ProgramStatus.Records[0].Progress) == 1
	}, "nonzero progress retained"), pane)
	h.programStatus(pane, "state=working:progress=0")
	f.waitLast(func(s feedSnapshot) bool {
		next, ok := feedRowFor(s, pane)
		return ok && next.ProgramStatus.Serial > r.ProgramStatus.Serial && len(next.ProgramStatus.Records) == 0
	}, "bare zero progress removed")
}

func feedRowFor(s feedSnapshot, pane string) (feedRow, bool) {
	for _, session := range s.Sessions {
		for _, r := range feedItems(session.Nodes) {
			if r.Pane != nil && *r.Pane == pane {
				return r, true
			}
		}
	}
	return feedRow{}, false
}

// A dead run pane is Ended at once, with the result its pane derives. The
// run's window stays the client's current one, which keeps the reaper from
// recording an outcome of its own.
func TestRpcEndedRunDerivesItsResultUntilItsOutcome(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.newWindow("alpha", "run", "sleep", "300")
	window := h.windowID(pane)
	h.in("set-window-option", "-t", window, "remain-on-exit", "on")
	h.in("set-option", "-p", "-t", pane, "@kido_run", "ended-run")
	h.agentRunMeta("ended-run", pane, "the run", "")
	h.in("select-window", "-t", window)
	f := h.startFeed("alpha")
	f.waitLast(func(s feedSnapshot) bool {
		r, ok := feedRowFor(s, pane)
		return ok && !r.Lifecycle.Ended && r.isShell() && r.Title == "the run" && r.Started != nil
	}, "the live run, titled by its name")
	h.in("respawn-pane", "-k", "-t", pane, "sh", "-c", "exit 3")
	f.waitLast(func(s feedSnapshot) bool {
		r, ok := feedRowFor(s, pane)
		return ok && r.Lifecycle.Ended && feedValue(r.Lifecycle.Result) == "failed" && r.Started == nil &&
			r.Run != nil && *r.Run == "ended-run" && r.Title == "the run"
	}, "the dead pane ended as failed, from its exit status")
	h.runKido("alpha", "outcome.out", "run-outcome", "--result", "completed", "--", "ended-run")
	f.waitLast(func(s feedSnapshot) bool {
		r, ok := feedRowFor(s, pane)
		return ok && r.Lifecycle.Ended && feedValue(r.Lifecycle.Result) == "completed"
	}, "the recorded result replaces unknown")
}

// Each feed numbers an outcome by the pane serial of the read where it saw
// the outcome arrive. A feed started after an unrelated update sees the same
// done under a later serial: an accepted loss, not an exactly-once identity.
func TestRpcFeedsNumberOutcomesByTheirOwnReads(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.newWindow("alpha", "native", nodeBin, "--")
	h.waitPaneCommand(pane, "node")
	outcome := func(f *feed, rawAbove int) (serial, raw int) {
		t.Helper()
		r, _ := feedRowFor(f.waitLast(func(s feedSnapshot) bool {
			r, ok := feedRowFor(s, pane)
			return ok && r.isAgent() && r.Lifecycle.Agent.Outcome != nil && r.ProgramStatus.Serial > rawAbove
		}, "an idle outcome"), pane)
		return feedValue(r.Lifecycle.Agent.Outcome.Serial), r.ProgramStatus.Serial
	}
	first := h.startFeed("alpha")
	h.programStatus(pane, "state=working:app=claude-code")
	first.waitLast(func(s feedSnapshot) bool {
		r, ok := feedRowFor(s, pane)
		return ok && r.isAgent() && r.Lifecycle.Agent.State == "Running"
	}, "working")
	h.programStatus(pane, "state=done:app=claude-code")
	serial, raw := outcome(first, 0)
	h.programStatus(pane, "state=done:app=claude-code:msg="+"YWdhaW4=")
	if again, newer := outcome(first, raw); again != serial || newer <= raw {
		t.Fatalf("an unchanged done changed the first feed's outcome: %d -> %d (raw %d -> %d)", serial, again, raw, newer)
	}
	second := h.startFeed("alpha")
	if other, _ := outcome(second, raw); other <= serial {
		t.Fatalf("a later feed's serial for the same done = %d, want later than the first feed's %d", other, serial)
	}
}
