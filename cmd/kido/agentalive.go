package main

import (
	"fmt"

	"kido/internal/state"
)

// agentAliveCmd implements `kido agent-alive INSTANCE`: prints "true" or
// "false", answering whether some agent session still reports INSTANCE as
// its own instance id. pi/kido-agents.ts's parent-liveness poll is its
// only caller - a subagent asking, every few seconds, whether the parent
// that spawned it is still there (docs/design.md, "Identity").
//
// It is its own subcommand rather than a flag on `kido list_agents` because it
// is a different question asked of a different reading. `kido list_agents` is
// a display: it lists panes to scope itself to one tmux session and
// collapses the result to one record per pane, both of which are right
// for something a human or the sidebar looks at and wrong here. A pane
// collision - a `pi --print` started inside an agent's pane inherits
// TMUX_PANE and wins that pane for as long as it reports - drops the real
// parent's record out of the per-pane view entirely, and a child reading
// that view concluded it might be an orphan. The same defect in the
// reaper killed two live agents (docs/design.md, "The orphan rule").
//
// So this reads state.LoadLive, every live record with nothing collapsed,
// and asks the only question the poll has: is this instance running. A
// collision decides who owns a pane and cannot disturb that answer. There
// is no tmux round trip either, which is what the poll's other reviewer
// was after: every five seconds per subagent, forever.
//
// Scope is therefore the whole registry rather than the caller's tmux
// session, which matches internal/reap's rule 2 - the other reader of
// this same fact, and already server-wide. A parent in another tmux
// session reads as alive to both.
//
// "false" is not an error: exit 0 either way, so the caller can tell a
// definite "gone" from kido being unreachable, which is never evidence.
func agentAliveCmd(args []string) error {
	if len(args) != 1 || args[0] == "" {
		return fmt.Errorf("usage: kido agent-alive INSTANCE")
	}
	live, err := state.LoadLive()
	if err != nil {
		return err
	}
	for _, s := range live {
		if s.Instance == args[0] {
			fmt.Println("true")
			return nil
		}
	}
	fmt.Println("false")
	return nil
}
