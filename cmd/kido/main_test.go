package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"kido/internal/hook"
	"kido/internal/state"
)

// TestRunHookDebugLog checks the debug.log line format: ts, TMUX_PANE, the
// raw payload compacted to one line, and the effect.
func TestRunHookDebugLog(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("KIDO_STATE_DIR", dir)
	t.Setenv("TMUX_PANE", "%7")

	payload := "{\n  \"hook_event_name\": \"Stop\",\n  \"session_id\": \"abc\"\n}"
	if err := runHook(strings.NewReader(payload), true); err != nil {
		t.Fatalf("runHook: %v", err)
	}
	// An event not in hook's table logs as "unmapped".
	if err := runHook(strings.NewReader(`{"hook_event_name":"FileChanged","session_id":"abc"}`), true); err != nil {
		t.Fatalf("runHook: %v", err)
	}

	b, err := os.ReadFile(filepath.Join(dir, "debug.log"))
	if err != nil {
		t.Fatalf("debug.log: %v", err)
	}
	lines := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	if len(lines) != 2 {
		t.Fatalf("got %d lines, want 2:\n%s", len(lines), b)
	}

	fields := strings.Split(lines[0], "\t")
	if len(fields) != 4 {
		t.Fatalf("line 1 fields = %d, want 4: %q", len(fields), lines[0])
	}
	if _, err := time.Parse(time.RFC3339Nano, fields[0]); err != nil {
		t.Errorf("timestamp %q: %v", fields[0], err)
	}
	if fields[1] != "%7" {
		t.Errorf("pane = %q, want %%7", fields[1])
	}
	if strings.Contains(fields[2], "\n") || !json.Valid([]byte(fields[2])) {
		t.Errorf("payload not compact valid JSON: %q", fields[2])
	}
	if fields[3] != "ended" {
		t.Errorf("effect = %q, want ended", fields[3])
	}

	fields2 := strings.Split(lines[1], "\t")
	if len(fields2) != 4 || fields2[3] != "unmapped" {
		t.Errorf("line 2 effect = %v, want unmapped", fields2)
	}

	// Without --debug, nothing is logged.
	dir2 := t.TempDir()
	t.Setenv("KIDO_STATE_DIR", dir2)
	if err := runHook(strings.NewReader(payload), false); err != nil {
		t.Fatalf("runHook: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir2, "debug.log")); !os.IsNotExist(err) {
		t.Errorf("debug.log created without --debug: %v", err)
	}
}

// TestSetupClaudeModeSwitch checks that setup-claude replaces existing
// kido entries (in either mode) and that switching between --debug and
// non-debug is idempotent.
func TestSetupClaudeModeSwitch(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")

	readHooks := func() map[string]any {
		b, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read settings: %v", err)
		}
		var settings map[string]any
		if err := json.Unmarshal(b, &settings); err != nil {
			t.Fatalf("unmarshal settings: %v", err)
		}
		hooks, _ := settings["hooks"].(map[string]any)
		return hooks
	}
	kidoCommand := func(hooks map[string]any, event string) (string, bool) {
		list, ok := hooks[event].([]any)
		if !ok {
			return "", false
		}
		for _, entry := range list {
			m := entry.(map[string]any)
			hs := m["hooks"].([]any)
			for _, h := range hs {
				hm := h.(map[string]any)
				if cmd, _ := hm["command"].(string); strings.Contains(cmd, "kido") {
					return cmd, true
				}
			}
		}
		return "", false
	}

	// Normal mode: only hook.Events() get an entry, command "kido hook".
	if n, err := writeClaudeSettings(path, false); err != nil || n != len(hook.Events()) {
		t.Fatalf("writeClaudeSettings(false) = %d, %v", n, err)
	}
	hooks := readHooks()
	if len(hooks) != len(hook.Events()) {
		t.Fatalf("registered %d events, want %d", len(hooks), len(hook.Events()))
	}
	for _, e := range hook.Events() {
		cmd, ok := kidoCommand(hooks, e)
		if !ok || cmd != "kido hook" {
			t.Errorf("event %s: command = %q, ok=%v", e, cmd, ok)
		}
	}

	// Switch to debug mode: every AllEvents() entry gets "kido hook
	// --debug", and there is exactly one kido entry per event (no
	// duplication from the previous run).
	if n, err := writeClaudeSettings(path, true); err != nil || n != len(hook.AllEvents()) {
		t.Fatalf("writeClaudeSettings(true) = %d, %v", n, err)
	}
	hooks = readHooks()
	if len(hooks) != len(hook.AllEvents()) {
		t.Fatalf("registered %d events, want %d", len(hooks), len(hook.AllEvents()))
	}
	for _, e := range hook.AllEvents() {
		list := hooks[e].([]any)
		count := 0
		for _, entry := range list {
			m := entry.(map[string]any)
			for _, h := range m["hooks"].([]any) {
				hm := h.(map[string]any)
				if cmd, _ := hm["command"].(string); strings.Contains(cmd, "kido") {
					count++
					if cmd != "kido hook --debug" {
						t.Errorf("event %s: command = %q", e, cmd)
					}
				}
			}
		}
		if count != 1 {
			t.Errorf("event %s: %d kido entries, want 1", e, count)
		}
	}

	// Switch back to normal mode: debug-only events lose their kido entry
	// entirely (and are dropped since nothing else was registered there).
	if n, err := writeClaudeSettings(path, false); err != nil || n != len(hook.Events()) {
		t.Fatalf("writeClaudeSettings(false) = %d, %v", n, err)
	}
	hooks = readHooks()
	if len(hooks) != len(hook.Events()) {
		t.Fatalf("registered %d events, want %d: %v", len(hooks), len(hook.Events()), hooks)
	}
	for _, e := range hook.Events() {
		cmd, ok := kidoCommand(hooks, e)
		if !ok || cmd != "kido hook" {
			t.Errorf("event %s: command = %q, ok=%v", e, cmd, ok)
		}
	}

	// A non-kido entry on a debug-only event survives the round trip.
	if n, err := writeClaudeSettings(path, true); err != nil || n != len(hook.AllEvents()) {
		t.Fatalf("writeClaudeSettings(true) = %d, %v", n, err)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var settings map[string]any
	if err := json.Unmarshal(b, &settings); err != nil {
		t.Fatal(err)
	}
	h := settings["hooks"].(map[string]any)
	h["FileChanged"] = append(h["FileChanged"].([]any), map[string]any{
		"hooks": []any{map[string]any{"type": "command", "command": "other-tool", "timeout": 5}},
	})
	out, err := json.MarshalIndent(settings, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, out, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := writeClaudeSettings(path, false); err != nil {
		t.Fatalf("writeClaudeSettings(false) = %v", err)
	}
	hooks = readHooks()
	list, ok := hooks["FileChanged"].([]any)
	if !ok || len(list) != 1 {
		t.Fatalf("FileChanged entries after non-debug setup = %v", hooks["FileChanged"])
	}
	entry := list[0].(map[string]any)
	hs := entry["hooks"].([]any)
	cmd, _ := hs[0].(map[string]any)["command"].(string)
	if cmd != "other-tool" {
		t.Errorf("FileChanged surviving entry = %q, want other-tool", cmd)
	}

	// A .bak backup is kept.
	if _, err := os.Stat(path + ".bak"); err != nil {
		t.Errorf("settings.json.bak missing: %v", err)
	}
}

func TestDebugLogPath(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("KIDO_STATE_DIR", dir)
	want := filepath.Join(dir, "debug.log")
	if got := filepath.Join(state.Dir(), "debug.log"); got != want {
		t.Errorf("debug-log path = %q, want %q", got, want)
	}
}
