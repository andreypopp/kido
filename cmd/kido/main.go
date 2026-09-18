// Command kido renders a tmux sidebar listing sessions and panes, with
// Claude Code sessions badged by activity status. It runs inside the side
// status line of the andreypopp/tmux fork (side-status-command).
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"kido/internal/hook"
	"kido/internal/procs"
	"kido/internal/state"
	"kido/internal/tmux"
	"kido/internal/ui"
)

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "hook":
			if err := runHook(os.Stdin); err != nil {
				fmt.Fprintln(os.Stderr, "kido hook:", err)
			}
			return // never fail the Claude Code hook
		case "setup-claude":
			if err := setupClaude(); err != nil {
				fmt.Fprintln(os.Stderr, "kido setup-claude:", err)
				os.Exit(1)
			}
			return
		case "snapshot":
			if err := snapshot(os.Stdout); err != nil {
				fmt.Fprintln(os.Stderr, "kido snapshot:", err)
				os.Exit(1)
			}
			return
		case "switch-session":
			if err := switchSession(os.Args[2:]); err != nil {
				fmt.Fprintln(os.Stderr, "kido switch-session:", err)
				os.Exit(1)
			}
			return
		}
	}

	opts := ui.Options{}
	flag.DurationVar(&opts.Interval, "interval", 100*time.Millisecond, "refresh interval; tmux changes also refresh immediately")
	flag.StringVar(&opts.Client, "client", "", "tmux client to act on; defaults to $TMUX_SIDE_CLIENT, then the current client")
	flag.Parse()

	if os.Getenv("TMUX") == "" {
		fmt.Fprintln(os.Stderr, "kido: must run inside tmux")
		os.Exit(1)
	}
	if opts.Client == "" {
		opts.Client = os.Getenv("TMUX_SIDE_CLIENT")
	}
	if opts.Client == "" {
		opts.Client = tmux.CurrentClient()
	}
	if err := ui.Run(opts); err != nil {
		fmt.Fprintln(os.Stderr, "kido:", err)
		os.Exit(1)
	}
}

// setupClaude registers `kido hook` for hookEvents in the Claude Code
// settings file, replacing any earlier kido hooks and keeping everything
// else. The previous file is kept as settings.json.bak.
func setupClaude() error {
	dir := os.Getenv("CLAUDE_CONFIG_DIR")
	if dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return err
		}
		dir = filepath.Join(home, ".claude")
	}
	path := filepath.Join(dir, "settings.json")

	settings := map[string]any{}
	old, err := os.ReadFile(path)
	switch {
	case err == nil:
		if err := json.Unmarshal(old, &settings); err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
	case !os.IsNotExist(err):
		return err
	}
	hooks, _ := settings["hooks"].(map[string]any)
	if hooks == nil {
		hooks = map[string]any{}
	}
	for _, event := range hook.Events() {
		var kept []any
		if list, ok := hooks[event].([]any); ok {
			for _, entry := range list {
				if !isKidoHook(entry) {
					kept = append(kept, entry)
				}
			}
		}
		hook := map[string]any{"type": "command", "command": "kido hook", "timeout": 5}
		if event != "SessionEnd" {
			hook["async"] = true // never delay Claude; SessionEnd must finish
		}
		hooks[event] = append(kept, map[string]any{"hooks": []any{hook}})
	}
	settings["hooks"] = hooks

	out, err := json.MarshalIndent(settings, "", "  ")
	if err != nil {
		return err
	}
	if old != nil {
		if err := os.WriteFile(path+".bak", old, 0o644); err != nil {
			return err
		}
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(path, append(out, '\n'), 0o644); err != nil {
		return err
	}
	fmt.Printf("registered kido hook for %d events in %s\n", len(hook.Events()), path)
	return nil
}

// switchSession implements `kido switch-session next|prev [-client NAME]`:
// it switches the current client to the adjacent session in kido's order
// (internal/tmux.SortSessions), wrapping around. The client flag may come
// before or after the direction, since a key binding's run-shell command is
// easiest to write with the flag last (bind -n S-Down run-shell "kido
// switch-session next -client '#{client_name}'").
func switchSession(args []string) error {
	var client, dir string
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if name, value, ok := strings.Cut(arg, "="); ok && (name == "-client" || name == "--client") {
			client = value
			continue
		}
		switch arg {
		case "-client", "--client":
			i++
			if i >= len(args) {
				return fmt.Errorf("%s needs a value", arg)
			}
			client = args[i]
		case "next", "prev":
			if dir != "" {
				return fmt.Errorf("only one of next/prev allowed")
			}
			dir = arg
		default:
			return fmt.Errorf("unknown argument %q", arg)
		}
	}
	if dir == "" {
		return fmt.Errorf("usage: kido switch-session next|prev [-client NAME]")
	}
	if client == "" {
		client = os.Getenv("TMUX_SIDE_CLIENT")
	}
	if client == "" {
		client = tmux.CurrentClient()
	}
	return tmux.SwitchSession(client, dir == "next")
}

// isKidoHook reports whether a hooks entry runs kido (any earlier form).
func isKidoHook(entry any) bool {
	m, _ := entry.(map[string]any)
	list, _ := m["hooks"].([]any)
	for _, h := range list {
		hm, _ := h.(map[string]any)
		if cmd, _ := hm["command"].(string); strings.Contains(cmd, "kido") {
			return true
		}
	}
	return false
}

// runHook is the Claude Code hook: it reads the event from stdin and
// records the session's status for the sidebar.
func runHook(r io.Reader) error {
	var in hook.Input
	if err := json.NewDecoder(r).Decode(&in); err != nil {
		return err
	}
	e := hook.Apply(in)
	switch {
	case e.Ignore:
		return nil
	case e.Remove:
		return state.Remove(in.SessionID)
	}
	now := time.Now().UTC()
	s := state.Session{
		Pane:   os.Getenv("TMUX_PANE"),
		PID:    procs.HookParent(), // the claude process, past the sh -c wrapper
		Status: e.Status,
		TS:     now,
	}
	if e.Ended {
		s.Ended = now
	}
	return state.Record(in.SessionID, s)
}
