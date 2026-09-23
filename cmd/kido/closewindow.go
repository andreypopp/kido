package main

import (
	"fmt"
	"os"
	"regexp"

	"kido/internal/tmux"
)

// windowIDPattern is the only spelling of a window id the commands that
// take one accept. close-window is why it is strict: its focus check
// compares the argument against tmux.Pane.WindowID, while kill-window
// resolves any tmux target syntax, so any other spelling passes the check
// (matching no pane) and then kills a window that may be the one the user
// is reading. window-focused passes its argument to no tmux target and so
// has no such hazard, but @N is the only shape tmux.Pane.WindowID ever
// takes, and refusing anything else fails loudly instead of always
// answering "false".
var windowIDPattern = regexp.MustCompile(`^@[0-9]+$`)

// killWindow is tmux.KillWindow, indirected so tests never talk to a tmux
// server.
var killWindow = tmux.KillWindow

// closeWindowCmd implements `kido close-window <window-id>`, what the
// linger helper runs after its delay. It checks once and does not retry:
// a window it leaves open is collected by the sweep (internal/reap) once
// the user leaves it.
func closeWindowCmd(args []string) error {
	if len(args) != 1 || args[0] == "" {
		return fmt.Errorf("usage: kido close-window WINDOW_ID")
	}
	windowID := args[0]
	if !windowIDPattern.MatchString(windowID) {
		return fmt.Errorf("close-window: %q is not a window id (@N)", windowID)
	}

	panes, err := listPanes()
	if err != nil {
		return err
	}
	if tmux.WindowFocused(panes, windowID) {
		fmt.Fprintf(os.Stderr, "kido close-window: %s is a client's current window; leaving it for the user to read\n", windowID)
		return nil
	}
	// Verified against a real server: kill-window on a session's last
	// window ends the session and every client attached to it.
	if tmux.LastWindow(panes, windowID) {
		fmt.Fprintf(os.Stderr, "kido close-window: %s is its session's only window; closing it would destroy the session\n", windowID)
		return nil
	}
	return killWindow(windowID)
}
