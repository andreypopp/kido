package e2e

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

func TestClaudeNativeProgramStatus(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.newWindow("alpha", "native", nodeBin, "--")
	h.waitPaneCommand(pane, "node")
	emit := func(line string) {
		t.Helper()
		h.in("send-keys", "-t", pane, "-l", line)
		h.in("send-keys", "-t", pane, "Enter")
	}
	emit("raw-title Claude Code")
	emit("osc state=idle:app=claude-code")
	h.waitGlyph("Claude Code", "")
	emit("raw-title ")
	h.waitGlyph("claude-code", "")
	emit("raw-title ✳ Reply with ok")
	f := h.startFeed("alpha")
	find := func(s feedSnapshot) (feedRow, bool) {
		for _, session := range s.Sessions {
			for _, r := range feedItems(session.Nodes) {
				if r.ID == pane {
					return r, true
				}
			}
		}
		return feedRow{}, false
	}
	// The blocked step is a new live episode, which clears the done from the idle after it.
	for _, c := range []struct {
		state, glyph, status, msg, outcome string
	}{
		{"idle", "", "Idle", "", ""},
		{"working", "◼", "Running", "", ""},
		{"done", "✓", "Idle", "", "success"},
		{"blocked", "◆", "Waiting", "approve Bash: touch x", ""},
		{"idle", "", "Idle", "", ""},
	} {
		body := "state=" + c.state + ":app=claude-code"
		if c.msg != "" {
			body += ":kind=permission:msg=" + base64.StdEncoding.EncodeToString([]byte(c.msg))
		}
		emit("osc " + body)
		caption := ""
		if c.msg != "" {
			caption = " " + c.msg
		}
		h.waitGlyph("✳ Reply with ok"+caption, c.glyph)
		f.waitLast(func(s feedSnapshot) bool {
			r, ok := find(s)
			if !ok || r.Lifecycle.Kind != "Some_agent" || feedValue(r.Lifecycle.Name) != "claude-code" {
				return false
			}
			a := r.Lifecycle.Agent
			outcome := ""
			if a.Outcome != nil {
				outcome = feedValue(a.Outcome.Result)
			}
			return r.Title == "✳ Reply with ok" && a.State == c.status && outcome == c.outcome &&
				(c.state != "blocked" || a.Kind != nil && *a.Kind == "permission") &&
				len(r.ProgramStatus.Records) == 1 && r.ProgramStatus.Records[0].State == c.state &&
				r.ProgramStatus.Records[0].ID == "" && r.ProgramStatus.Records[0].App == "claude-code" &&
				r.ProgramStatus.Records[0].Msg == c.msg && (c.state != "blocked" || r.ProgramStatus.Records[0].Kind == "permission") &&
				(c.msg == "" || a.Msg != nil && *a.Msg == c.msg)
		}, "Claude native "+c.state)
	}
	out, rc := h.kidoAs(h.firstPane("alpha"), "", nil, "tool", "list_runs", "--json")
	var listed []map[string]any
	if json.Unmarshal([]byte(out), &listed) != nil || rc != 0 || len(listed) != 0 {
		t.Fatalf("native pane acquired an addressable identity: %d %q", rc, out)
	}
	out, rc = h.kidoAs(h.firstPane("alpha"), "", nil, "get-agent", "native")
	var identity struct{ Alive bool }
	if json.Unmarshal([]byte(out), &identity) != nil || rc != 0 || identity.Alive {
		t.Fatalf("native pane became a session identity: %d %q", rc, out)
	}
	out, rc = h.kidoAs(h.firstPane("alpha"), "hi", nil, "tool", "message_agent", "--", "Reply with ok")
	if rc == 0 || !strings.Contains(out, "no agent session matches") {
		t.Fatalf("native pane became message-addressable: %d %q", rc, out)
	}
	out, rc = h.kidoAs(h.firstPane("alpha"), "a prompt", nil, "prompt")
	if rc != 0 {
		t.Fatalf("prompt to native pane: %d %q", rc, out)
	}
	h.waitPaneText(pane, "got: a prompt")
	emit("osc state=clear")
	f.waitLast(func(s feedSnapshot) bool {
		r, ok := find(s)
		return ok && r.isShell() && r.Lifecycle.Shell.Report == nil && len(r.ProgramStatus.Records) == 0 &&
			r.Title == "node"
	}, "clear restores terminal row")
	h.waitFor(func() bool { return !strings.Contains(strings.Join(h.rows(), "\n"), "Reply with ok") }, settle, msgf("cleared Claude label"))
}
