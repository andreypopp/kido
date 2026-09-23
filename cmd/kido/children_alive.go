package main

import (
	"fmt"

	"kido/internal/subrun"
)

// childrenAliveCmd implements `kido children-alive INSTANCE`: prints
// "true" or "false", answering whether any run INSTANCE started is still
// going. pi/kido-agents.ts's idle self-exit is its only caller - a child
// about to shut itself down asking whether it is the only thing it
// started that would be shut down with it (docs/design-subagents.md,
// "Idle self-exit").
//
// It is the mirror of `kido agent-alive`, and is its own subcommand for
// the same reason: a different question asked of a different reading.
// agent-alive reads the state registry, which holds a record only while a
// process is running and says nothing about who spawned it; this reads
// the run records, which are the durable half and the only place a parent
// edge outlives a turn. `kido runs` shows exactly the same two facts -
// parent and outcome - from the same files.
//
// "Alive" is subrun.EffectiveOutcome's "not ended yet": no outcome
// recorded and a pid still running. A child whose process is gone but
// whose outcome has not landed yet - the window between a crash and the
// sweep that records it - reads as ended, which is the safe direction: a
// parent waiting on a child that no longer exists would never go idle
// again.
//
// "false" is not an error: exit 0 either way, so the caller can tell a
// definite "nothing running" from kido being unreachable, which is never
// evidence.
func childrenAliveCmd(args []string) error {
	if len(args) != 1 || args[0] == "" {
		return fmt.Errorf("usage: kido children-alive INSTANCE")
	}
	ids, err := subrun.List()
	if err != nil {
		return err
	}
	for _, id := range ids {
		meta, err := subrun.ReadMeta(id)
		if err != nil || meta.ParentInstance != args[0] {
			continue
		}
		if _, ended, err := subrun.EffectiveOutcome(id, meta.PID); err == nil && !ended {
			fmt.Println("true")
			return nil
		}
	}
	fmt.Println("false")
	return nil
}
