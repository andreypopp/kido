package main

import (
	"fmt"
	"io"
	"strings"
	"time"

	"kido/internal/state"
	"kido/internal/tmux"
)

// snapshot writes a shell script that recreates the server's sessions,
// windows, panes, directories and layouts, resuming Claude Code panes by
// their exact session id where the hook has recorded one.
func snapshot(w io.Writer) error {
	panes, err := tmux.ListPanes()
	if err != nil {
		return err
	}
	states, _ := state.Load()
	q := func(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

	fmt.Fprintf(w, "#!/bin/sh\n# tmux sessions captured by kido snapshot on %s.\n", time.Now().Format("2006-01-02 15:04"))
	fmt.Fprintln(w, "# Run outside tmux, then attach. Claude Code panes resume their session.")
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
		if p.CurrentCommand == "claude" {
			cmd := "claude --continue"
			if st, ok := states[p.PaneID]; ok && st.ID != "" {
				cmd = "claude --resume " + st.ID
			}
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
