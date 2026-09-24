package main

import (
	"fmt"
	"os"
	"regexp"

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

// unmarkSubagent is tmux.UnmarkSubagent, indirected for the same reason.
var unmarkSubagent = tmux.UnmarkSubagent

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
	if tmux.WindowFocused(panes, windowID) {
		// The whole window, for either unit: the user switched here to read
		// what the run left, and a pane killed under them takes that screen
		// away and resizes what is left of the window.
		fmt.Fprintf(os.Stderr, "kido close-run: %s is a client's current window; leaving it for the user to read\n", windowID)
		return nil
	}

	runPane, ok := runPaneOf(panes, windowID)
	if ok && !runPane.Dead {
		fmt.Fprintf(os.Stderr, "kido close-run: %s's run is still going; leaving it\n", windowID)
		return nil
	}
	if ok && !tmux.LastPane(panes, windowID) {
		// The user's own split is in there. Kill the run's pane alone, and
		// unmark the window: with the run collected it is theirs, and every
		// reader of the mark - the tree, switch-window, a later sweep -
		// must stop treating it as kido's.
		if err := killPane(runPane.PaneID); err != nil {
			return err
		}
		return unmarkSubagent(windowID)
	}
	// Either the run's pane is all the window has, or the window was
	// marked before kido recorded which pane the run was in - and then a
	// window is finished only once all of it is, since nothing tells the
	// run's own pane from a pane the user split off later.
	if !ok && !tmux.WindowAllDead(panes, windowID) {
		fmt.Fprintf(os.Stderr, "kido close-run: %s still has a live pane; leaving it for the sweep\n", windowID)
		return nil
	}
	// Verified against a real server: kill-window on a session's last
	// window ends the session and every client attached to it.
	if tmux.LastWindow(panes, windowID) {
		fmt.Fprintf(os.Stderr, "kido close-run: %s is its session's only window; closing it would destroy the session\n", windowID)
		return nil
	}
	return killWindow(windowID)
}

// runPaneOf is the pane of windowID the run itself is in
// (tmux.SubagentPaneOption), and false for a window with none: one kido
// never created, or one marked before that option existed.
func runPaneOf(panes []tmux.Pane, windowID string) (tmux.Pane, bool) {
	for _, p := range panes {
		if p.WindowID == windowID && p.SubagentPane != "" {
			return p, true
		}
	}
	return tmux.Pane{}, false
}
