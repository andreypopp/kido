package main

import (
	"fmt"
	"os"
	"regexp"

	"kido/internal/tmux"
)

// windowIDPattern is what close-window accepts, and nothing else. The
// focus check below compares the argument against tmux.Pane.WindowID,
// while kill-window resolves any tmux target syntax - a name, an index,
// "session:window" - so any spelling but the window id itself passes the
// check (matching no pane) and is then resolved by tmux to a window that
// may well be the one the user is reading. `kido close-window <name>`
// killed a focused window that way. The linger helper always passes the
// window id `kido agents --json` reported, so refusing everything else
// costs its one caller nothing.
var windowIDPattern = regexp.MustCompile(`^@[0-9]+$`)

// killWindow is tmux.KillWindow, indirected the same way listPanes
// (message.go) and newWindow (spawn.go) are, so closeWindowCmd and
// reapCmd never talk to a real tmux server in a test.
var killWindow = tmux.KillWindow

// closeWindowCmd implements `kido close-window <window-id>`: the linger
// helper a finishing subagent spawns before it exits runs this, after a
// delay, to close the window it leaves behind (see
// docs/subagents-plan.md's Lifecycle section). windowID is killed unless
// it is the current window of some attached client - the user may have
// switched to it to read the subagent's last screen, and closing out from
// under them would lose exactly what the linger was for.
//
// The helper checks once and does not retry, and does not need to: the
// window it leaves open is a marked window whose pane is dead, which is
// exactly what the periodic sweep (internal/reap, run from the sidebar's
// poll) collects once the user leaves it. The retry the plan described
// was the only way to finish the job when the sweep depended on a state
// record that was already gone by then; it no longer does.
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
	// Closing a session's only window destroys the session itself, and a
	// subagent whose window is the last one left is not worth a session
	// (verified against a real server: kill-window on the last window ends
	// the session and every client attached to it).
	if tmux.LastWindow(panes, windowID) {
		fmt.Fprintf(os.Stderr, "kido close-window: %s is its session's only window; closing it would destroy the session\n", windowID)
		return nil
	}
	return killWindow(windowID)
}
