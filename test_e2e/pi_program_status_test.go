package e2e

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestPiTerminalStatusIdentityAndStall(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.piPane("alpha", "not the session name")
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
	emit := func(state, title string) {
		t.Helper()
		h.in("send-keys", "-t", pane, "-l", "osc state="+state+":app=pi:title="+title)
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
	h.waitFor(func() bool { return listed("unknown", "", false) }, settle, msgf("stale identity without a root never stalls"))
	writeTimestamp(time.Now())
	for _, c := range []struct{ state, glyph string }{{"working", "◼"}, {"blocked", "◆"}, {"done", "✓"}} {
		emit(c.state, "VGVybWluYWw=")
		h.waitGlyph("Terminal", c.glyph)
		h.waitFor(func() bool { return listed(c.state, "Terminal", false) }, settle, msgf("terminal %s in list_runs", c.state))
	}
	emit("working", "VGVybWluYWw=")
	h.waitGlyph("Terminal", "◼")
	writeTimestamp(time.Now().Add(-time.Hour))
	h.waitGlyph("Terminal", "!")
	h.waitFor(func() bool { return listed("working", "Terminal", true) }, settle, msgf("stale working terminal stalls"))

	caller := h.firstPane("alpha")
	h.programStatus(caller, "state=idle:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", caller, "#{pane_title}"), "π - "))
	h.agentStatus("asker", caller, "pi", "--inbox", startInbox(t, "ok\n").Path)
	node, err := exec.LookPath("node")
	if err != nil {
		t.Fatal(err)
	}
	extension, _ := filepath.Abs("../share/pi/kido-agents.ts")
	script := filepath.Join(h.dir, "ask.mjs")
	source := fmt.Sprintf(`import agents from %q;
import { execFileSync } from "node:child_process";
const tools = new Map();
globalThis.__kidoPiExtensionSeam = { agents: null, host: {
 sessionId: () => "asker",
 inboxOpen: () => true,
 runKido: async (args) => ({ ok: true, out: execFileSync(%q, args, { encoding: "utf8", timeout: 2000 }) })
}};
agents({ on() {}, registerTool: (tool) => tools.set(tool.name, tool), registerMessageRenderer() {} });
const result = await tools.get("ask_agent").execute("ask", { to: "Terminal", question: "ready?", timeoutMs: 100 });
console.log(result.content[0].text);
`, extension, kidoBin)
	if err := os.WriteFile(script, []byte(source), 0o644); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, node, script)
	cmd.Env = cleanEnv("TMUX="+h.inner+",0,0", "TMUX_PANE="+caller)
	out, err := cmd.CombinedOutput()
	if err != nil || !strings.Contains(string(out), "reporting working; likely stalled, refusing") || len(in.Received()) != 0 {
		t.Fatalf("stalled ask: %v %q, inbox %v", err, out, in.Received())
	}
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
	emit("blocked", "TmVzdGVk")
	h.waitGlyph("Nested", "◆")
	writeTimestamp(time.Now().Add(-time.Hour))
	h.waitFor(func() bool { return listed("blocked", "Nested", false) }, settle, msgf("nested program owns the root title and status"))
	bare := h.piPane("alpha", "bare pi")
	h.in("send-keys", "-t", bare, "-l", "osc state=working:app=pi:title=QmFyZQ==")
	h.in("send-keys", "-t", bare, "Enter")
	h.waitGlyph("Bare", "◼")
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		if !strings.Contains(h.rowFor("Bare"), "◼Bare") {
			t.Fatalf("bare pi stalled: %s", h.rowFor("Bare"))
		}
		<-time.After(100 * time.Millisecond)
	}
}
