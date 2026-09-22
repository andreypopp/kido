package main

import (
	"fmt"
	"time"

	"kido/internal/reap"
	"kido/internal/state"
)

// reapCmd implements `kido reap`: one sweep of the window lifecycle's
// backstop, by hand. The sweep itself is reap.Sweep, which the sidebar
// runs on every poll (internal/ui) - that, not this command, is what
// actually collects a subagent window in a live session, since nothing
// invokes a command a human has to remember to type. This one exists so
// the sweep has an entry point a test and an operator can drive directly,
// and runs exactly the same rules.
//
// It reads with state.ReadAll rather than state.Load for the reason
// ReadAll documents, though the difference no longer decides anything:
// Sweep's first rule reads no record at all, and its second checks
// liveness for itself.
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
	for _, windowID := range reap.Sweep(panes, all, time.Now()) {
		killWindow(windowID) //nolint:errcheck // best effort; another sweep or the linger helper may have closed it first
	}
	return nil
}
