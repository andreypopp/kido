package main

import (
	"fmt"
	"time"

	"kido/internal/reap"
	"kido/internal/state"
)

// state.ReadAll, not Load: the orphan rule needs every record, since a
// per-pane view can drop the very record that proves a parent is alive.
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
