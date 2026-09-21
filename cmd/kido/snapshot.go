package main

import (
	"fmt"
	"io"
	"time"

	"kido/internal/procs"
	"kido/internal/state"
	"kido/internal/tmux"
)

// snapshot writes a shell script that recreates the server's sessions,
// windows, panes, directories and layouts, resuming Claude Code and pi
// panes by their exact session id where a hook or agent-status call has
// recorded one.
func snapshot(w io.Writer) error {
	panes, err := tmux.ListPanes()
	if err != nil {
		return err
	}
	states, _ := state.Load()
	// snapshot runs once and exits, unlike the sidebar's repeated polling, so
	// the cost of a process-table scan here is a one-off: it is what lets an
	// unreported pi pane (pane_current_command is just "node", see
	// procs.MaybePi) be told apart from a plain shell.
	piPanes := procs.Sweep().Pi
	q := tmux.Quote

	fmt.Fprintf(w, "#!/bin/sh\n# tmux sessions captured by kido snapshot on %s.\n", time.Now().Format("2006-01-02 15:04"))
	fmt.Fprintln(w, "# Run outside tmux, then attach. Claude Code and pi panes resume their session.")
	fmt.Fprintln(w, "set -e\nT=${TMUX_BIN:-tmux}")

	// list-panes -a is ordered session, window, pane; a window's layout is
	// applied once all its panes exist, so each window ends by "closing".
	var layout string
	closeWindow := func() {
		if layout != "" {
			fmt.Fprintf(w, "$T select-layout -t \"$p0\" %s\n", q(layout))
			layout = ""
		}
	}
	prevSession, prevWindow, n := "", -1, 0
	for _, p := range panes {
		newSession := p.SessionName != prevSession
		if newSession || p.WindowIndex != prevWindow {
			closeWindow()
			name := ""
			if p.WindowName != "" {
				name = " -n " + q(p.WindowName)
			}
			if newSession {
				fmt.Fprintf(w, "\n# --- %s\n", p.SessionName)
				fmt.Fprintf(w, "p0=$($T new-session -d -P -F '#{pane_id}' -s %s%s -c %s)\n", q(p.SessionName), name, q(p.CurrentPath))
			} else {
				fmt.Fprintf(w, "p0=$($T new-window -d -P -F '#{pane_id}' -t %s%s -c %s)\n", q(p.SessionName), name, q(p.CurrentPath))
			}
			prevSession, prevWindow, n, layout = p.SessionName, p.WindowIndex, 0, p.WindowLayout
		} else {
			n++
			fmt.Fprintf(w, "p%d=$($T split-window -d -P -F '#{pane_id}' -t \"$p%d\" -c %s)\n", n, n-1, q(p.CurrentPath))
		}
		if cmd := paneCommand(p, states, piPanes); cmd != "" {
			fmt.Fprintf(w, "$T send-keys -t \"$p%d\" %s Enter\n", n, q(cmd))
		}
		if p.Active {
			fmt.Fprintf(w, "$T select-window -t \"$p%d\"; $T select-pane -t \"$p%d\"\n", n, n)
		}
	}
	closeWindow()
	fmt.Fprintln(w, `echo "recreated: $($T list-sessions -F '#{session_name}' | tr '\n' ' ')"`)
	return nil
}

// paneCommand picks the command, if any, snapshot's script should send into
// the pane it just recreated to put its agent back where it was. states is
// keyed by pane id the way state.Load returns it, and is the primary source
// for what a pane is running: a pane's recorded Session names both the
// agent (claude or pi) and, as its key, that agent's own session id, the
// same way the Claude Code path always worked. A pane with no record falls
// back to what can be told from its foreground command alone -
// pane_current_command "claude" for Claude Code - or, for pi, from piPanes
// (procs.Sweep().Pi, keyed by pane pid). A pane that matches none of this
// (a plain shell, or any other program) gets no command at all.
//
// The new pane already starts in the recreated pane's directory (the
// new-session/new-window/split-window call above always passes -c), which
// is what a resumed pi session needs: pi namespaces sessions by working
// directory, so resuming the wrong one would either fail to find the id or
// (with --session-id) silently create it fresh in the wrong project.
func paneCommand(p tmux.Pane, states map[string]state.Session, piPanes map[int]bool) string {
	if st, ok := states[p.PaneID]; ok {
		switch st.Agent {
		case state.AgentPi:
			if st.ID == "" {
				return "pi"
			}
			// --session resumes the exact session file (by path, exact id,
			// or partial uuid); --session-id would instead create the id if
			// it does not already exist, which is wrong when recreating a
			// session snapshot knows existed.
			return "pi --session " + st.ID
		case state.AgentClaude:
			if st.ID != "" {
				return "claude --resume " + st.ID
			}
			return "claude --continue"
		}
		// An agent kido does not otherwise recognise: fall through to what
		// the pane's own command or the process sweep can tell.
	}
	if p.CurrentCommand == "claude" {
		return "claude --continue"
	}
	if piPanes[p.PanePID] {
		return "pi"
	}
	return ""
}
