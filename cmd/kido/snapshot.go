package main

import (
	"fmt"
	"io"
	"os/exec"
	"strings"
	"time"

	"kido/internal/state"
)

// snapshot writes a shell script that recreates the server's sessions,
// windows, panes, directories and layouts, resuming Claude Code sessions
// by their exact id where the hook has recorded one.
func snapshot(w io.Writer) error {
	const sep = "\x1f"
	out, err := exec.Command("tmux", "list-panes", "-a", "-F", strings.Join([]string{
		"#{session_name}", "#{window_index}", "#{window_name}", "#{window_layout}",
		"#{pane_id}", "#{pane_current_path}", "#{pane_current_command}",
		"#{window_active}", "#{pane_active}",
	}, sep)).Output()
	if err != nil {
		return fmt.Errorf("tmux list-panes: %w", err)
	}
	states, _ := state.Load()

	type pane struct {
		id, path, cmd string
		active        bool
	}
	type window struct {
		index, name, layout string
		active              bool
		panes               []pane
	}
	type session struct {
		name    string
		windows []*window
	}
	var sessions []*session
	byName := map[string]*session{}
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		f := strings.Split(line, sep)
		if len(f) != 9 {
			continue
		}
		s := byName[f[0]]
		if s == nil {
			s = &session{name: f[0]}
			byName[f[0]] = s
			sessions = append(sessions, s)
		}
		var win *window
		if n := len(s.windows); n > 0 && s.windows[n-1].index == f[1] {
			win = s.windows[n-1]
		} else {
			win = &window{index: f[1], name: f[2], layout: f[3], active: f[7] == "1"}
			s.windows = append(s.windows, win)
		}
		win.panes = append(win.panes, pane{id: f[4], path: f[5], cmd: f[6], active: f[8] == "1"})
	}

	q := func(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }
	fmt.Fprintf(w, "#!/bin/sh\n# tmux sessions captured by kido snapshot on %s.\n", time.Now().Format("2006-01-02 15:04"))
	fmt.Fprintln(w, "# Run outside tmux, then attach. Claude Code panes resume their session.")
	fmt.Fprintln(w, "set -e\nT=${TMUX_BIN:-tmux}")
	for _, s := range sessions {
		fmt.Fprintf(w, "\n# --- %s\n", s.name)
		var activeWindow bool
		for i, win := range s.windows {
			name := ""
			if win.name != "" {
				name = " -n " + q(win.name)
			}
			if i == 0 {
				fmt.Fprintf(w, "w=$($T new-session -d -P -F '#{window_id}' -s %s%s -c %s)\n", q(s.name), name, q(win.panes[0].path))
			} else {
				fmt.Fprintf(w, "w=$($T new-window -d -P -F '#{window_id}' -t %s%s -c %s)\n", q(s.name), name, q(win.panes[0].path))
			}
			fmt.Fprintln(w, `p0=$($T display-message -p -t "$w" '#{pane_id}')`)
			for n := 1; n < len(win.panes); n++ {
				fmt.Fprintf(w, "p%d=$($T split-window -d -P -F '#{pane_id}' -t \"$p%d\" -c %s)\n", n, n-1, q(win.panes[n].path))
			}
			fmt.Fprintf(w, "$T select-layout -t \"$w\" %s\n", q(win.layout))
			for n, p := range win.panes {
				if p.cmd != "claude" {
					continue
				}
				cmd := "claude --continue"
				if st, ok := states[p.id]; ok && st.ID != "" {
					cmd = "claude --resume " + st.ID
				}
				fmt.Fprintf(w, "$T send-keys -t \"$p%d\" %s Enter\n", n, q(cmd))
			}
			for n, p := range win.panes {
				if p.active {
					fmt.Fprintf(w, "$T select-pane -t \"$p%d\"\n", n)
				}
			}
			if win.active {
				fmt.Fprintln(w, `aw=$w`)
				activeWindow = true
			}
		}
		if activeWindow {
			fmt.Fprintln(w, `$T select-window -t "$aw"`)
		}
	}
	fmt.Fprintln(w, `echo "recreated: $($T list-sessions -F '#{session_name}' | tr '\n' ' ')"`)
	return nil
}
