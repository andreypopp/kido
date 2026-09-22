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
	// A one-off process-table scan tells an unreported pi pane (which
	// tmux reports as "node") from a plain shell.
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

// paneCommand picks the command, if any, snapshot's script should send
// into the pane it just recreated: from the pane's state record when it
// has one, else from its foreground command or the process sweep. The
// script always passes -c, which a resumed pi session needs: pi
// namespaces sessions by working directory.
func paneCommand(p tmux.Pane, states map[string]state.Session, piPanes map[int]bool) string {
	if st, ok := states[p.PaneID]; ok {
		switch st.Agent {
		case state.AgentPi:
			if st.ID == "" {
				return "pi"
			}
			// --session resumes an existing session; --session-id would
			// create it if missing.
			return "pi --session " + st.ID
		case state.AgentClaude:
			if st.ID != "" {
				return "claude --resume " + st.ID
			}
			return "claude --continue"
		}
	}
	if p.CurrentCommand == "claude" {
		return "claude --continue"
	}
	if piPanes[p.PanePID] {
		return "pi"
	}
	return ""
}
