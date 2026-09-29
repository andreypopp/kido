package main

import (
	"fmt"
	"os"
	"regexp"

	"kido/internal/reap"
	"kido/internal/tmux"
)

// windowIDPattern is the only spelling of a window id the commands that
// take one accept. close-run is why it is strict: its focus check
// compares the argument against tmux.Pane.WindowID, while kill-window
// resolves any tmux target syntax, so any other spelling passes the check
// (matching no pane) and then kills a window that may be the one the user
// is reading. window-focused passes its argument to no tmux target and so
// has no such hazard, but @N is the only shape tmux.Pane.WindowID ever
// takes, and refusing anything else fails loudly instead of always
// answering "false".
var windowIDPattern = regexp.MustCompile(`^@[0-9]+$`)

// killWindow is tmux.KillWindow, indirected so tests never talk to a tmux
// server. killPane is the same, in control.go.
var killWindow = tmux.KillWindow

// releaseOps binds cmd/kido's two indirected tmux acts to the one helper
// that carries out a close (reap.Ops.Release). It is a function rather
// than a value so a test swapping either is read at the call, not at
// package init.
func releaseOps() reap.Ops {
	return reap.Ops{KillWindow: killWindow, KillPane: killPane}
}

// closeRunCmd implements `kido close-run <window-id>`, what the linger
// helper runs after its delay: collect the finished run in that window.
// The unit is the run's own pane, so a window holding the user's split
// beside it keeps the split and goes on as an ordinary window; a window
// the run is all of is closed, which is what this did for every window
// before. It checks once and does not retry: whatever it leaves is
// collected by the sweep (internal/reap) once the user leaves it.
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
