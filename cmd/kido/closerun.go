package main

import (
	"fmt"
	"os"
	"regexp"

	"kido/internal/reap"
	"kido/internal/tmux"
)

// close-run is why this is strict: its focus check compares the argument
// against tmux.Pane.WindowID, while kill-window resolves any tmux target
// syntax, so any other spelling passes the check (matching no pane) and
// then kills a window that may be the one the user is reading.
var windowIDPattern = regexp.MustCompile(`^@[0-9]+$`)

var killWindow = tmux.KillWindow

// A function rather than a value, so a test swapping killWindow or
// killPane is read at the call, not at package init.
func releaseOps() reap.Ops {
	return reap.Ops{KillWindow: killWindow, KillPane: killPane}
}

// The unit closed is the run's own pane: a window holding the user's
// split beside it keeps the split and goes on as an ordinary window. It
// checks once and does not retry; whatever it leaves is collected by the
// sweep (internal/reap) once the user leaves it.
func closeRunCmd(args []string) error {
	if len(args) != 1 || args[0] == "" {
		return fmt.Errorf("usage: kido close-run WINDOW_ID")
	}
	windowID := args[0]
	if !windowIDPattern.MatchString(windowID) {
		return fmt.Errorf("close-run: %q is not a window id (@N)", windowID)
	}

	panes, err := listPanes()
	if err != nil {
		return err
	}
	c, refusal := reap.Decide(panes, windowID)
	if refusal != "" {
		fmt.Fprintf(os.Stderr, "kido close-run: %s\n", refusal)
		return nil
	}
	return releaseOps().Release(c)
}
