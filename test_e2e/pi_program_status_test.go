package e2e

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestPiTerminalStatusIdentityAndStall(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.piPane("alpha", "Terminal")
	in := startInbox(t, "ok\n")
	if out, rc := h.kidoAs(pane, "", nil, "agent-status", "--agent", "pi", "--session", "terminal-pi", "--inbox", in.Path); rc != 0 {
		t.Fatalf("identity: %d %s", rc, out)
	}
	rec := h.stateRecord("terminal-pi")
	for _, field := range []string{"status", "ended", "background", "toolPending", "title"} {
		if _, exists := rec[field]; exists {
			t.Fatalf("terminal identity carries %s: %v", field, rec)
		}
	}
	emit := func(state string) {
		t.Helper()
		h.in("send-keys", "-t", pane, "-l", "osc state="+state+":app=pi")
		h.in("send-keys", "-t", pane, "Enter")
	}
	listed := func(status, name string, stalled bool) bool {
		out, rc := h.kidoAs(h.firstPane("alpha"), "", nil, "tool", "list_runs", "--json")
		var rows []struct {
			ID, Status, Name string
			Stalled          bool
		}
		if err := json.Unmarshal([]byte(out), &rows); err != nil || rc != 0 {
			t.Fatalf("list_runs: rc=%d %v %q", rc, err, out)
		}
		for _, row := range rows {
			if row.ID == "terminal-pi" {
				return row.Status == status && row.Name == name && row.Stalled == stalled
			}
		}
		return false
	}
	writeTimestamp := func(at time.Time) {
		t.Helper()
		rec["ts"] = at.UTC().Format(time.RFC3339Nano)
		bytes, _ := json.Marshal(rec)
		if err := os.WriteFile(filepath.Join(h.stateDir, "terminal-pi.json"), bytes, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	writeTimestamp(time.Now().Add(-time.Hour))
	h.waitFor(func() bool { return listed("unknown", "Terminal", false) }, settle, msgf("stale identity without a root never stalls"))
	writeTimestamp(time.Now())
	for _, c := range []struct{ state, glyph string }{{"working", "◼"}, {"blocked", "◆"}, {"done", "✓"}} {
		emit(c.state)
		h.waitGlyph("Terminal", c.glyph)
		h.waitFor(func() bool { return listed(c.state, "Terminal", false) }, settle, msgf("terminal %s in list_runs", c.state))
	}
	emit("working")
	h.waitGlyph("Terminal", "◼")
	writeTimestamp(time.Now().Add(-time.Hour))
	h.waitGlyph("Terminal", "!")
	h.waitFor(func() bool { return listed("working", "Terminal", true) }, settle, msgf("stale working terminal stalls"))

	wake := filepath.Join(h.stateDir, "wake")
	if err := os.WriteFile(wake, []byte(time.Now().UTC().Format(time.RFC3339Nano)), 0o644); err != nil {
		t.Fatal(err)
	}
	h.waitGlyph("Terminal", "◼")
	h.waitFor(func() bool { return listed("working", "Terminal", false) }, settle, msgf("a recent wake suppresses stale working"))
	if err := os.Remove(wake); err != nil {
		t.Fatal(err)
	}
	h.waitGlyph("Terminal", "!")
	writeTimestamp(time.Now())
	h.waitGlyph("Terminal", "◼")
	h.waitFor(func() bool { return listed("working", "Terminal", false) }, settle, msgf("a fresh heartbeat clears a stall"))
	h.programStatus(pane, "state=blocked:app=pi:kind=question", "Nested")
	h.waitGlyph("Nested", "◆")
	writeTimestamp(time.Now().Add(-time.Hour))
	h.waitFor(func() bool { return listed("blocked", "Nested", false) }, settle, msgf("pane title names pi while its root supplies status"))
	bare := h.piPane("alpha", "Bare")
	h.in("send-keys", "-t", bare, "-l", "osc state=working:app=pi:msg=QmFyZQ==")
	h.in("send-keys", "-t", bare, "Enter")
	h.waitGlyph("Bare", "◼")
	if row := h.rowFor("Bare"); strings.Count(row, "Bare") != 1 {
		t.Fatalf("native session name duplicated in caption: %s", row)
	}
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		if !strings.Contains(h.rowFor("Bare"), "◼Bare") {
			t.Fatalf("bare pi stalled: %s", h.rowFor("Bare"))
		}
		<-time.After(100 * time.Millisecond)
	}
	h.in("send-keys", "-t", bare, "-l", "osc state=clear")
	h.in("send-keys", "-t", bare, "Enter")
	h.waitFor(func() bool {
		return !strings.Contains(h.in("display-message", "-p", "-t", bare, "#{pane_program_status}"), "\"state\"")
	}, settle, msgf("native clear without app removes the root"))
}
