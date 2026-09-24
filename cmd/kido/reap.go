package main

import (
	"fmt"
	"time"

	"kido/internal/reap"
	"kido/internal/state"
)

// reapCmd implements `kido reap`: one reap.Sweep by hand, for a test or
// an operator; the sidebar's poll runs the same sweep continuously. It
// reads with state.ReadAll for two reasons: it does not delete the
// records it reasons about, and it collapses nothing, which is what the
// orphan rule requires - a per-pane view can drop the very record that
// proves a parent is alive (internal/reap, Sweep).
func reapCmd(args []string) error {
	if len(args) != 0 {
		return fmt.Errorf("usage: kido reap")
	}
	sessions, err := state.ReadAll()
	if err != nil {
		return err
	}
	panes, err := listPanes()
	if err != nil {
		return err
	}
	all := make([]state.Session, 0, len(sessions))
	for _, s := range sessions {
		all = append(all, s)
	}
	closing, notices := reap.Sweep(panes, all, time.Now())
	for _, c := range closing {
		applyClose(c)
	}
	// After the closes, because this is the one observer that may block:
	// a notice is a socket round trip to an agent that might be wedged,
	// and the window it describes is better closed first.
	for _, n := range notices {
		noticeFor(n).send("reap")
	}
	return nil
}

// applyClose does what a sweep asked for: kill the run's pane and hand
// the window back to whatever the user left in it, or close the window
// when the run was all of it. Every call is best effort - another sweep,
// or the linger helper, may have got there first, and each of them is
// racing the others by design.
func applyClose(c reap.Close) {
	if c.Window() {
		killWindow(c.WindowID) //nolint:errcheck // best effort; it may already be gone
		return
	}
	killPane(c.PaneID)         //nolint:errcheck // best effort; it may already be gone
	unmarkSubagent(c.WindowID) //nolint:errcheck // best effort; the window may have gone with the pane
}
