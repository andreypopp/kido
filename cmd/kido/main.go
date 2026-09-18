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

	"kido/internal/state"
	"kido/internal/tmux"
	"kido/internal/ui"
)

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "hook":
			if err := hook(os.Stdin); err != nil {
				fmt.Fprintln(os.Stderr, "kido hook:", err)
			}
			return // never fail the Claude Code hook
		case "setup-claude":
			if err := setupClaude(); err != nil {
				fmt.Fprintln(os.Stderr, "kido setup-claude:", err)
				os.Exit(1)
			}
			return
		}
	}

	opts := ui.Options{}
	flag.DurationVar(&opts.Interval, "interval", 500*time.Millisecond, "refresh interval")
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

// hookEvents are the Claude Code events setup-claude registers the hook
// for; hook dispatches on hook_event_name.
var hookEvents = []string{
	"SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
	"PostToolUse", "PermissionRequest", "Stop", "Notification",
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
	for _, event := range hookEvents {
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
	fmt.Printf("registered kido hook for %d events in %s\n", len(hookEvents), path)
	return nil
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

// hook is the Claude Code hook: it reads the event from stdin and records
// the session's status for the sidebar.
func hook(r io.Reader) error {
	var in struct {
		Event            string `json:"hook_event_name"`
		SessionID        string `json:"session_id"`
		NotificationType string `json:"notification_type"`
	}
	if err := json.NewDecoder(r).Decode(&in); err != nil {
		return err
	}
	if in.SessionID == "" {
		return nil
	}
	var status state.Status
	switch in.Event {
	case "SessionEnd":
		return state.Remove(in.SessionID)
	case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure":
		status = state.Running
	case "SessionStart", "Stop":
		status = state.Idle
	case "PermissionRequest", "Elicitation":
		status = state.Waiting
	case "Notification":
		switch in.NotificationType {
		case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
			status = state.Waiting
		default:
			return nil
		}
	default:
		return nil
	}
	return state.Record(in.SessionID, state.Session{
		Pane:   os.Getenv("TMUX_PANE"),
		PID:    os.Getppid(), // the claude process runs the hook
		Status: status,
		TS:     time.Now().UTC(),
	})
}
