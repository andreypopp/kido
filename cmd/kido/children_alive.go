package main

import (
	"fmt"

	"kido/internal/subrun"
)

// "Alive" is subrun.EffectiveOutcome's "not ended yet": no outcome
// recorded and a pid still running. A child whose process is gone but
// whose outcome has not landed yet reads as ended, the safe direction: a
// parent waiting on a child that no longer exists would never go idle again.
//
// "false" is not an error: exit 0 either way, so the caller can tell a
// definite "nothing running" from kido being unreachable, which is never
// evidence.
func childrenAliveCmd(args []string) error {
	if len(args) != 1 || args[0] == "" {
		return fmt.Errorf("usage: kido children-alive SESSION")
	}
	ids, err := subrun.List()
	if err != nil {
		return err
	}
	for _, id := range ids {
		meta, err := subrun.ReadMeta(id)
		if err != nil || meta.ParentSession != args[0] {
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
