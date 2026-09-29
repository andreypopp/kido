package main

import (
	"flag"
	"fmt"
	"io"
	"os"

	"kido/internal/state"
)

func setStatusUsage() string { return "usage: kido set_status -- ACTIVITY" }

// An empty argument clears the activity. The previous record is read back
// with only that field replaced, so status, staleness, a turn's end time
// and the background flag all survive untouched.
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
