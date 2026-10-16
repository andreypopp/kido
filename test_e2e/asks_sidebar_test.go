package e2e

import (
	"strings"
	"testing"
)

func TestSidebarAsksIndicatorAndMode(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.newWindow("alpha", "agent", "sh", "-c", "exec sleep 300")
	in := startInbox(t, "ok\n")
	h.programStatus(pane, "state=blocked:app=pi", "Decider")
	h.agentStatus("asking-session", pane, "--inbox", in.Path)
	id, code := h.kidoAs(pane, "Ship?\nSecond line", nil, "tool", "ask_user")
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
					return row.isAgent() && row.Lifecycle.Agent.State == "Waiting" &&
						row.Lifecycle.Agent.Source == "Ask" && feedValue(row.Lifecycle.Agent.Ask) == id
				}
			}
		}
		return false
	}
	f.waitLast(asking, "waiting on the ask in rpc")
	h.programStatus(pane, "state=done:app=pi", "Decider")
	h.agentStatus("asking-session", pane, "--inbox", in.Path)
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
	f.waitLast(func(s feedSnapshot) bool { return s.Client.Pane == pane && asking(s) }, "a visited ask still waits")
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
	h.programStatus(pane, "state=idle:app=pi", "Decider")
	h.agentStatus("standalone-ask", pane)
	id, code := h.kidoAs(pane, "Question?", nil, "tool", "ask_user")
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

func TestAskUserSelfReplacementAndExternalRemoval(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	_, pane := h.agentWithInbox("alpha", "external-ask")
	in := startInbox(t, "ok\n")
	h.programStatus(pane, "state=idle:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", pane, "#{pane_title}"), "π - "))
	h.agentStatus("external-ask", pane, "--inbox", in.Path)
	id, code := h.kidoAs(pane, "Original", nil, "tool", "ask_user")
	if code != 0 {
		t.Fatal(id)
	}
	out, code := h.kidoAs(pane, "Reworded", nil, "tool", "ask_user", "--replaces", id)
	if code != 0 || out != id || len(in.Received()) != 0 {
		t.Fatalf("own replacement: exit %d, %s, messages %q", code, out, in.Received())
	}
	out, code = h.kidoAs("", "", nil, "tool", "remove_ask", id)
	if code != 0 || len(in.Received()) != 1 {
		t.Fatalf("external removal: exit %d, %s, messages %q", code, out, in.Received())
	}
	if env, ok := parseEnvelope(in.Received()[0]); !ok || env.Kind != "asks" || env.Text != "The user removed ask "+id+": Reworded" {
		t.Fatalf("invalidation: %s", in.Received()[0])
	}
}
