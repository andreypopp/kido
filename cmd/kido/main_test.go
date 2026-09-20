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

// TestRunHookEndedPreservesEarlierEnd checks that an Ended effect keeps an
// existing idle record's Ended time rather than overwriting it with now,
// since a later event minting Ended for the same turn is a less
// authoritative observation than the one already recorded.
func TestRunHookEndedPreservesEarlierEnd(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("KIDO_STATE_DIR", dir)
	t.Setenv("TMUX_PANE", "%7")

	// No existing record: Ended is stamped to now.
	before := time.Now().UTC()
	if err := runHook(strings.NewReader(`{"hook_event_name":"Stop","session_id":"s"}`), false); err != nil {
		t.Fatalf("runHook: %v", err)
	}
	after := time.Now().UTC()
	states, err := state.Load()
	if err != nil {
		t.Fatalf("state.Load: %v", err)
	}
	got := states["%7"].Ended
	if got.Before(before) || got.After(after) {
		t.Fatalf("Ended = %v, want between %v and %v", got, before, after)
	}
	firstEnded := got

	// A second event that also mints Ended for the same session keeps the
	// earlier, already-recorded Ended rather than overwriting it with now.
	time.Sleep(2 * time.Millisecond)
	if err := runHook(strings.NewReader(`{"hook_event_name":"Notification","notification_type":"idle_prompt","session_id":"s"}`), false); err != nil {
		t.Fatalf("runHook: %v", err)
	}
	states, err = state.Load()
	if err != nil {
		t.Fatalf("state.Load: %v", err)
	}
	if got := states["%7"].Ended; !got.Equal(firstEnded) {
		t.Errorf("Ended = %v, want preserved %v", got, firstEnded)
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

// TestAgentStatus checks the record `kido agent-status` writes for an
// agent that is not Claude Code.
func TestAgentStatus(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("KIDO_STATE_DIR", dir)
	t.Setenv("TMUX_PANE", "%12")

	if err := agentStatus([]string{"--agent", "pi", "--session", "p1", "--status", "running"}); err != nil {
		t.Fatalf("agentStatus: %v", err)
	}
	s, ok, err := state.Get("p1")
	if err != nil || !ok {
		t.Fatalf("state.Get: %v, ok=%v", err, ok)
	}
	if s.Agent != state.AgentPi || s.Pane != "%12" || s.Status != state.Running {
		t.Errorf("record = %+v, want a running pi record for %%12", s)
	}
	if s.PID <= 0 {
		t.Errorf("pid = %d, want the calling agent's pid", s.PID)
	}
	if s.TS.IsZero() || !s.Ended.IsZero() {
		t.Errorf("ts=%v ended=%v, want a timestamp and no end", s.TS, s.Ended)
	}

	// --title is accepted (and not recorded: the sidebar reads the pane
	// title), --ended stamps an end.
	if err := agentStatus([]string{"--agent", "pi", "--session", "p1",
		"--status", "idle", "--title", "π - kido", "--ended"}); err != nil {
		t.Fatalf("agentStatus --ended: %v", err)
	}
	s, _, err = state.Get("p1")
	if err != nil {
		t.Fatal(err)
	}
	if s.Status != state.Idle || s.Ended.IsZero() {
		t.Fatalf("record = %+v, want idle with an end", s)
	}
	firstEnded := s.Ended

	// An end describes when the turn ended, not when kido noticed: a
	// second report of the same turn keeps the earlier end.
	time.Sleep(2 * time.Millisecond)
	if err := agentStatus([]string{"--agent", "pi", "--session", "p1", "--status", "idle", "--ended"}); err != nil {
		t.Fatalf("agentStatus: %v", err)
	}
	if s, _, _ = state.Get("p1"); !s.Ended.Equal(firstEnded) {
		t.Errorf("ended = %v, want preserved %v", s.Ended, firstEnded)
	}

	// --remove drops the record, and is idempotent.
	for range 2 {
		if err := agentStatus([]string{"--agent", "pi", "--session", "p1", "--remove"}); err != nil {
			t.Fatalf("agentStatus --remove: %v", err)
		}
	}
	if _, ok, _ := state.Get("p1"); ok {
		t.Error("record still there after --remove")
	}
}

// TestAgentStatusErrors checks the argument shapes that must fail.
func TestAgentStatusErrors(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("KIDO_STATE_DIR", dir)
	t.Setenv("TMUX_PANE", "%12")

	for _, c := range []struct {
		name string
		args []string
	}{
		{"no status", []string{"--agent", "pi", "--session", "p1"}},
		{"unknown status", []string{"--agent", "pi", "--session", "p1", "--status", "busy"}},
		{"kido's own status", []string{"--agent", "pi", "--session", "p1", "--status", "unknown"}},
		{"no agent", []string{"--session", "p1", "--status", "idle"}},
		{"no session", []string{"--agent", "pi", "--status", "idle"}},
		{"unknown flag", []string{"--agent", "pi", "--session", "p1", "--status", "idle", "--what"}},
		{"stray argument", []string{"--agent", "pi", "--session", "p1", "--status", "idle", "x"}},
	} {
		if err := agentStatus(c.args); err == nil {
			t.Errorf("%s: no error", c.name)
		}
	}
	if entries, _ := os.ReadDir(dir); len(entries) > 0 {
		t.Errorf("failed calls wrote %d files", len(entries))
	}
}
