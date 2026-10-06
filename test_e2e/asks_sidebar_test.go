package e2e

import (
	"path/filepath"
	"testing"
)

func TestSidebarAsksIndicatorAndMode(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.newWindow("alpha", "agent", "sh", "-c", "exec sleep 300")
	in := startInbox(t, "ok\n")
	h.agentStatus("asking-session", pane, "pi", "waiting", "--title", "Decider", "--inbox", in.Path)
	file := filepath.Join(h.dir, "session.jsonl")
	id, code := askCommand(h, pane, "Ship?\nSecond line", "tool", "ask_user", "--session", "asking-session", "--session-file", file)
	if code != 0 {
		t.Fatalf("ask: exit %d, %s", code, id)
	}
	h.waitRow("◆Decider")
	if len(in.Received()) != 0 {
		t.Fatal("own tool action sent a widget invalidation")
	}
	f := h.startFeed("alpha")
	asking := func(s feedSnapshot) bool {
		for _, session := range s.Sessions {
			for _, row := range feedItems(session.Nodes) {
				if row.Pane != nil && *row.Pane == pane {
					return row.Indicator != nil && row.Indicator.Kind == "waiting" && row.Attention
				}
			}
		}
		return false
	}
	f.waitLast(asking, "waiting indicator and attention in rpc")
	h.agentStatus("asking-session", pane, "pi", "idle", "--title", "Decider", "--inbox", in.Path, "--ended")
	h.waitRow("◆Decider")
	focusSidebar(h)
	h.sendKeys("/")
	h.sendKeys("a")
	h.waitFor(func() bool { return hasLine(h.sidebar(), "/a") }, settle, msgf("a stays in filter input"))
	h.sendKeys("Escape")
	h.waitFor(func() bool { return !hasLine(h.sidebar(), "/a") }, settle, msgf("filter input cleared"))
	h.sendKeys("a")
	h.waitRow("asks")
	h.waitSelected("Decider " + id + " Ship?")
	if hasLine(h.sidebar(), "Second line") {
		t.Fatal("asks mode did not limit text to its first line")
	}
	h.sendKeys("Enter")
	h.waitFor(func() bool {
		return h.in("display-message", "-p", "-t", "alpha:", "#{pane_id}") == pane
	}, settle, msgf("ask jumps to its live pane"))
	h.waitFocused(false)
	f.waitLast(func(s feedSnapshot) bool { return s.Client.Pane == pane && asking(s) }, "visited asks remain attention")
	focusSidebar(h)
	h.sendKeys("Escape")
	h.waitRow("◆Decider")
	h.waitFocused(true)
	h.sendKeys("a")
	h.waitSelected(id)
	h.sendKeys("d")
	h.waitFor(func() bool { return len(openAsks(h, "")) == 0 }, settle, msgf("sidebar removes the selected ask"))
	h.waitFor(func() bool { return len(in.Received()) == 1 }, settle, msgf("widget invalidation sent"))
	if env, ok := parseEnvelope(in.Received()[0]); !ok || env.Kind != "asks" || env.Text != "The user removed ask "+id+": Ship?" {
		t.Fatalf("invalidation: %+v", in.Received())
	}
	h.sendKeys("Escape")
	h.waitFor(func() bool { return !hasLine(h.sidebar(), "◆Decider") }, settle, msgf("waiting indicator cleared"))
}

func TestSidebarAsksStandaloneEscape(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.in("display-message", "-p", "-t", "alpha:", "#{pane_id}")
	h.agentStatus("standalone-ask", pane, "pi", "idle", "--title", "Decider")
	id, code := askCommand(h, pane, "Question?", "tool", "ask_user", "--session-file", filepath.Join(h.dir, "session.jsonl"))
	if code != 0 {
		t.Fatal(id)
	}
	p := startPicker(h, "alpha")
	p.keys("a")
	p.waitSelected(id)
	p.keys("Escape")
	p.waitExit()
	if len(openAsks(h, "standalone-ask")) != 1 {
		t.Fatal("Escape removed the ask")
	}
}

func TestAskUserExternalReplacementInvalidatesWidget(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	_, pane := h.agentWithInbox("alpha", "external-ask")
	in := startInbox(t, "ok\n")
	h.agentStatus("external-ask", pane, "pi", "idle", "--inbox", in.Path)
	file := filepath.Join(h.dir, "session.jsonl")
	id, code := askCommand(h, pane, "Original", "tool", "ask_user", "--session", "external-ask", "--session-file", file)
	if code != 0 {
		t.Fatal(id)
	}
	out, code := askCommand(h, pane, "Reworded", "tool", "ask_user", "--replaces", id, "--session-file", file)
	if code != 0 || out != id || len(in.Received()) != 1 {
		t.Fatalf("external replacement: exit %d, %s, messages %q", code, out, in.Received())
	}
	out, code = askCommand(h, pane, "", "tool", "remove_ask", id)
	if code != 0 || len(in.Received()) != 2 {
		t.Fatalf("external removal: exit %d, %s, messages %q", code, out, in.Received())
	}
	for i, raw := range in.Received() {
		env, ok := parseEnvelope(raw)
		text := ""
		if i == 1 {
			text = "The user removed ask " + id + ": Reworded"
		}
		if !ok || env.Kind != "asks" || env.Text != text {
			t.Fatalf("invalidation: %s", raw)
		}
	}
}
