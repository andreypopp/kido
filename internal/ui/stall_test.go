package ui

import (
	"strings"
	"testing"
	"time"

	"kido/internal/state"
	"kido/internal/tmux"
)

// TestStallRedrawsOnAQuietTick drives Update with a snapshot that never
// changes, which is exactly what a wedged agent looks like from outside:
// its pane is alive, tmux has nothing new to say about it, and its state
// record stopped moving when it stopped reporting.
//
// This is the regression stallPending exists for, and it is the same trap
// TestShellDebounceRedraws pins for shellPending: state.Stalled is driven
// by kido's own clock, so with the gate gone - or read after the tick
// instead of before it, when m.at already equals now and the comparison
// can never differ - paneLabel still returns the right glyph and the row
// freezes on screen at "running", because rebuild is never called.
func TestStallRedrawsOnAQuietTick(t *testing.T) {
	const pane = "%1"
	base := time.Unix(1700000000, 0)
	clock := base

	saved := state.StallThreshold
	state.StallThreshold = time.Minute
	t.Cleanup(func() { state.StallThreshold = saved })

	m := model{
		started: base.Add(-time.Hour),
		seen:    map[string]time.Time{},
		phases:  map[string]shellPhase{},
		now:     func() time.Time { return clock },
	}
	m.at = m.now()

	// The record is written once, at base, and never again: the agent
	// reported Running and then went quiet.
	snap := snapshot{
		current: "alpha",
		active:  pane,
		panes:   []tmux.Pane{{SessionName: "alpha", WindowID: "@1", PaneID: pane, Title: "wedged"}},
		states: map[string]state.Session{
			pane: {Pane: pane, Agent: state.AgentPi, Status: state.Running, TS: base, Instance: "i"},
		},
	}
	tick := func(d time.Duration) {
		clock = clock.Add(d)
		next, _ := m.Update(snap)
		m = next.(model)
	}
	stalled := func() bool {
		for _, r := range m.rows {
			if r.paneID == pane {
				return strings.Contains(r.text, indicatorStalled())
			}
		}
		t.Fatalf("no row for %s: %v", pane, m.rows)
		return false
	}

	tick(0)
	if stalled() {
		t.Error("the row is marked stalled before the report is StallThreshold old")
	}
	tick(30 * time.Second)
	if stalled() {
		t.Error("the row is marked stalled halfway to the threshold")
	}
	tick(30 * time.Second)
	if !stalled() {
		t.Error("the row is not marked stalled on the tick that crossed the threshold")
	}
}

// TestSnapshotSameIgnoresHeartbeatTS pins sameStates' exclusion of
// state.Session.TS: pi/kido-status.ts now re-sends a running session's
// unchanged status every HEARTBEAT_MS purely to keep TS fresh for
// state.Stalled, and without the exclusion that alone would make same()
// report a change - forcing a full sidebar rebuild on every agent's
// heartbeat, the same objection AGENTS.md raises against
// pane_command_duration.
func TestSnapshotSameIgnoresHeartbeatTS(t *testing.T) {
	base := time.Unix(1700000000, 0)
	a := snapshot{states: map[string]state.Session{
		"%1": {Pane: "%1", Agent: state.AgentPi, Status: state.Running, TS: base, Instance: "i"},
	}}
	b := snapshot{states: map[string]state.Session{
		"%1": {Pane: "%1", Agent: state.AgentPi, Status: state.Running, TS: base.Add(time.Minute), Instance: "i"},
	}}
	if !a.same(b) {
		t.Error("a TS-only change (a heartbeat re-report) should not make same() report a difference")
	}
}

// TestSnapshotSameCatchesOtherSessionChanges is the negative control for
// the exclusion above: it must not widen past TS. same() fails toward
// extra redraws (AGENTS.md), so a change to any other Session field must
// still be caught.
func TestSnapshotSameCatchesOtherSessionChanges(t *testing.T) {
	base := time.Unix(1700000000, 0)
	a := snapshot{states: map[string]state.Session{
		"%1": {Pane: "%1", Agent: state.AgentPi, Status: state.Running, TS: base, Instance: "i"},
	}}
	b := snapshot{states: map[string]state.Session{
		"%1": {Pane: "%1", Agent: state.AgentPi, Status: state.Idle, TS: base, Instance: "i"},
	}}
	if a.same(b) {
		t.Error("a Status change must still be caught by same()")
	}
}
