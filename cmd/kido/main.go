// Command kido renders a tmux sidebar listing sessions and panes, with
// Claude Code sessions badged by activity status. It runs inside the side
// status line of the andreypopp/tmux fork (side-status-command).
package main

import (
	"bytes"
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

// hasFlag reports whether args contains name as -name or --name.
func hasFlag(args []string, name string) bool {
	for _, a := range args {
		if a == "-"+name || a == "--"+name {
			return true
		}
	}
	return false
}

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "hook":
			debug := hasFlag(os.Args[2:], "debug")
			if err := runHook(os.Stdin, debug); err != nil {
				fmt.Fprintln(os.Stderr, "kido hook:", err)
			}
			return // never fail the Claude Code hook
		case "setup-claude":
			debug := hasFlag(os.Args[2:], "debug")
			if err := setupClaude(debug); err != nil {
				fmt.Fprintln(os.Stderr, "kido setup-claude:", err)
				os.Exit(1)
			}
			return
		case "debug-log":
			fmt.Println(filepath.Join(state.Dir(), "debug.log"))
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
		case "prompt":
			os.Exit(prompt(os.Args[2:], os.Stdin))
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

// setupClaude registers `kido hook` (or, with debug, `kido hook --debug`
// for every Claude Code hook event) in the user's Claude Code settings
// file, replacing any earlier kido hooks and keeping everything else. The
// previous file is kept as settings.json.bak.
func setupClaude(debug bool) error {
	dir := os.Getenv("CLAUDE_CONFIG_DIR")
	if dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return err
		}
		dir = filepath.Join(home, ".claude")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	path := filepath.Join(dir, "settings.json")
	n, err := writeClaudeSettings(path, debug)
	if err != nil {
		return err
	}
	fmt.Printf("registered kido hook for %d events in %s\n", n, path)
	return nil
}

// writeClaudeSettings registers kido's hook command for the target event
// set (hook.Events(), or hook.AllEvents() when debug) at path, replacing
// any earlier kido hook entries (in either mode) and removing kido entries
// for events outside the target set, so switching modes back and forth is
// idempotent. It returns the number of events registered.
func writeClaudeSettings(path string, debug bool) (int, error) {
	settings := map[string]any{}
	old, err := os.ReadFile(path)
	switch {
	case err == nil:
		if err := json.Unmarshal(old, &settings); err != nil {
			return 0, fmt.Errorf("%s: %w", path, err)
		}
	case !os.IsNotExist(err):
		return 0, err
	}
	hooks, _ := settings["hooks"].(map[string]any)
	if hooks == nil {
		hooks = map[string]any{}
	}

	command := "kido hook"
	targetEvents := hook.Events()
	if debug {
		command = "kido hook --debug"
		targetEvents = hook.AllEvents()
	}
	target := map[string]bool{}
	for _, event := range targetEvents {
		target[event] = true
	}

	// Strip stale kido entries left by a previous run in the other mode,
	// for events outside the current target set.
	for _, event := range hook.AllEvents() {
		if target[event] {
			continue
		}
		list, ok := hooks[event].([]any)
		if !ok {
			continue
		}
		var kept []any
		for _, entry := range list {
			if !isKidoHook(entry) {
				kept = append(kept, entry)
			}
		}
		if len(kept) == 0 {
			delete(hooks, event)
		} else {
			hooks[event] = kept
		}
	}

	for _, event := range targetEvents {
		var kept []any
		if list, ok := hooks[event].([]any); ok {
			for _, entry := range list {
				if !isKidoHook(entry) {
					kept = append(kept, entry)
				}
			}
		}
		h := map[string]any{"type": "command", "command": command, "timeout": 5}
		if event != "SessionEnd" {
			h["async"] = true // never delay Claude; SessionEnd must finish
		}
		hooks[event] = append(kept, map[string]any{"hooks": []any{h}})
	}
	settings["hooks"] = hooks

	out, err := json.MarshalIndent(settings, "", "  ")
	if err != nil {
		return 0, err
	}
	if old != nil {
		if err := os.WriteFile(path+".bak", old, 0o644); err != nil {
			return 0, err
		}
	}
	if err := os.WriteFile(path, append(out, '\n'), 0o644); err != nil {
		return 0, err
	}
	return len(targetEvents), nil
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
// records the session's status for the sidebar. With debug, every event
// (mapped or not) is appended to debug.log before anything else runs.
func runHook(r io.Reader, debug bool) error {
	raw, err := io.ReadAll(r)
	if err != nil {
		return err
	}
	var in hook.Input
	if err := json.Unmarshal(raw, &in); err != nil {
		return err
	}
	e := hook.Apply(in)
	if debug {
		logHookEvent(raw, in, e)
	}
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

// logHookEvent appends one line to <state.Dir()>/debug.log: a timestamp,
// TMUX_PANE, the raw hook payload compacted to one line, and the effect
// hook.Apply returned. A failure to log is ignored; it must never break
// the hook.
func logHookEvent(raw []byte, in hook.Input, e hook.Effect) {
	dir := state.Dir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return
	}
	f, err := os.OpenFile(filepath.Join(dir, "debug.log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	var compact bytes.Buffer
	if json.Compact(&compact, raw) != nil {
		compact.Reset()
		compact.Write(bytes.ReplaceAll(raw, []byte("\n"), []byte(" ")))
	}
	line := fmt.Sprintf("%s\t%s\t%s\t%s\n",
		time.Now().Format(time.RFC3339Nano), os.Getenv("TMUX_PANE"), compact.String(), effectString(in, e))
	f.WriteString(line) //nolint:errcheck // logging must never fail the hook
}

// effectString renders a hook.Effect the way debug.log records it:
// "unmapped" for events outside hook's table, else "remove", "ended",
// "ignore", or "status=<status>".
func effectString(in hook.Input, e hook.Effect) string {
	if !hook.Mapped(in.Event) {
		return "unmapped"
	}
	switch {
	case e.Remove:
		return "remove"
	case e.Ended:
		return "ended"
	case e.Ignore:
		return "ignore"
	default:
		return "status=" + string(e.Status)
	}
}
