package main

import (
	"fmt"
	"time"

	"kido/internal/reap"
	"kido/internal/state"
)

// reapCmd implements `kido reap`: one reap.Collect by hand, for a test or
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
	reap.Collect(panes, sessions, time.Now(), releaseOps())
	return nil
}
