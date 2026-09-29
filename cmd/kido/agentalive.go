package main

import (
	"fmt"

	"kido/internal/state"
)

// This reads state.LoadLive rather than the per-pane view `kido
// list_agents` uses: a pane collision (a `pi --print` started inside an
// agent's pane inherits TMUX_PANE) drops the real parent's record out of
// the per-pane view entirely, and a child reading that view would
// conclude it might be an orphan.
//
// "false" is not an error: exit 0 either way, so the caller can tell a
// definite "gone" from kido being unreachable, which is never evidence.
func agentAliveCmd(args []string) error {
	if len(args) != 1 || args[0] == "" {
		return fmt.Errorf("usage: kido agent-alive SESSION")
	}
	live, err := state.LoadLive()
	if err != nil {
		return err
	}
	if _, ok := state.Find(live, args[0]); ok {
		fmt.Println("true")
		return nil
	}
	fmt.Println("false")
	return nil
}
