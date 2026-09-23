package main

import (
	"flag"
	"fmt"
	"io"
	"os"

	"kido/internal/state"
)

func setStatusUsage() string { return "usage: kido set_status -- ACTIVITY" }

// setStatusCmd implements `kido set_status -- <activity>`: it sets the
// free-text activity on the calling session's own record and changes
// nothing else. The activity is positional rather than a flag, so the
// command reads as the tool of the same name does
// (docs/design-subagents.md, "The tools, and their commands"); an empty
// argument clears it.
//
// This is deliberately not a rename of `kido agent-status`, which reports
// a session's whole state (fourteen flags, of which --activity is one) on
// every turn and keeps its name. The narrow command exists so the narrow
// tool has one, and it writes the record the same way: the previous record
// read back with one field replaced, so status, staleness (TS), a turn's
// end time and the background flag all survive a set_status untouched.
// An agent's next `kido agent-status` report carries the activity forward
// itself when it omits --activity.
//
// The calling session is found by pane, the way an envelope's sender is
// (senderOf, message_agent.go): a pane with no agent record has no
// activity to set, and is an error rather than a silent no-op.
func setStatusCmd(args []string) error {
	fs := flag.NewFlagSet("set_status", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("%w\n%s", err, setStatusUsage())
	}
	if fs.NArg() != 1 {
		return fmt.Errorf("%s", setStatusUsage())
	}

	states, err := state.Load()
	if err != nil {
		return err
	}
	pane := os.Getenv("TMUX_PANE")
	s, ok := states[pane]
	if !ok {
		return fmt.Errorf("no agent session has reported pane %q; there is nothing to set an activity on", pane)
	}
	s.Activity = oneLine(fs.Arg(0), maxActivity)
	return state.Record(s.ID, s)
}
