package e2e

import (
	"bytes"
	"fmt"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func TestRpcHelloAndRequests(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	f := h.startFeed("alpha")
	waitLine := func(want string) {
		t.Helper()
		h.waitFor(func() bool {
			f.mu.Lock()
			defer f.mu.Unlock()
			for _, s := range f.lines {
				if s.raw == want {
					return true
				}
			}
			return false
		}, settle, msgf("RPC line %s", want))
	}
	waitLine(`{"hello":{"protocol":"2.1"}}`)
	f.mu.Lock()
	first := f.lines[0].raw
	f.mu.Unlock()
	if first != `{"hello":{"protocol":"2.1"}}` {
		t.Fatalf("first line: %s", first)
	}
	session := h.in("display-message", "-p", "-t", "alpha:", "#{session_id}")
	firstWindow := h.in("display-message", "-p", "-t", "alpha:", "#{window_id}")
	f.send(`{"id":1,"switch-window":{"direction":"next"}}`)
	waitLine(fmt.Sprintf(`{"reply":{"id":1,"switched":{"session":%q,"window":%q}}}`, session, firstWindow))
	f.send(`{"id":2,"unknown":true}`)
	waitLine(`{"reply":{"id":2,"error":"invalid or unknown request"}}`)
	f.send(`{"id":3,"switch-window":{"direction":"sideways"}}`)
	waitLine(`{"reply":{"id":3,"error":"invalid or unknown request"}}`)
	h.newWindow("alpha", "second")
	window := h.in("display-message", "-p", "-t", "alpha:second", "#{window_id}")
	f.send(`{"id":4,"switch-window":{"direction":"next"}}`)
	waitLine(fmt.Sprintf(`{"reply":{"id":4,"switched":{"session":%q,"window":%q}}}`, session, window))
	if got := h.in("display-message", "-p", "-c", f.client, "#{window_id}"); got != window {
		t.Fatalf("switched to %s, want %s", got, window)
	}
	f.send(`{"id":5,"switch-session":{"direction":"next"}}`)
	waitLine(`{"reply":{"id":5,"switched":null}}`)
	f.send(`{"id":6,"switch-session":{"direction":"prev"}}`)
	waitLine(`{"reply":{"id":6,"switched":null}}`)
	f.send(`{"id":7,"switch-session":{"direction":"sideways"}}`)
	waitLine(`{"reply":{"id":7,"error":"invalid or unknown request"}}`)
	f.send(`{"filter":"nothing-matches"}`)
	f.send(`{"id":12,"filter":"nothing-matches"}`)
	waitLine(`{"reply":{"id":12,"error":"invalid or unknown request"}}`)
	h.newSessionSpaced("aardvark")
	otherSession := h.in("display-message", "-p", "-t", "aardvark:", "#{session_id}")
	otherWindow := h.in("display-message", "-p", "-t", "aardvark:", "#{window_id}")
	f.waitLast(func(s feedSnapshot) bool {
		return len(s.Sessions) == 2 && s.Sessions[0].ID == session && s.Sessions[1].ID == otherSession
	}, "sessions in sidebar order")
	for i, step := range []struct{ direction, session, window string }{
		{"next", otherSession, otherWindow},
		{"next", session, window},
		{"prev", otherSession, otherWindow},
		{"prev", session, window},
	} {
		id := 8 + i
		f.send(fmt.Sprintf(`{"id":%d,"switch-session":{"direction":%q}}`, id, step.direction))
		waitLine(fmt.Sprintf(`{"reply":{"id":%d,"switched":{"session":%q,"window":%q}}}`, id, step.session, step.window))
		if got := h.in("display-message", "-p", "-c", f.client, "#{session_id} #{window_id}"); got != step.session+" "+step.window {
			t.Fatalf("switch-session %s: got %s, want %s %s", step.direction, got, step.session, step.window)
		}
	}
}

func TestRpcSwitchWindowTree(t *testing.T) {
	t.Parallel()
	h := start(t, "a")
	h.renameWindow("a", 0, "root")
	h.liveParent("a", "root-session")
	h.addWindow("a", "top")
	_, child := h.subagentWindow("a", "child", "child-session", "root-session")
	_, grandchild := h.subagentWindow("a", "grandchild", "grandchild-session", "child-session")
	_, grandSibling := h.subagentWindow("a", "grand-sibling", "grand-sibling-session", "child-session")
	_, sibling := h.subagentWindow("a", "sibling", "sibling-session", "root-session")
	h.addWindow("a", "orphan")
	h.markSubagent("a", "orphan")
	h.newSessionSpaced("b")
	root := h.in("display-message", "-p", "-t", "a:root", "#{window_id}")
	top := h.in("display-message", "-p", "-t", "a:top", "#{window_id}")
	other := h.in("display-message", "-p", "-t", "b:", "#{window_id}")
	session := h.in("display-message", "-p", "-t", "a:", "#{session_id}")
	otherSession := h.in("display-message", "-p", "-t", "b:", "#{session_id}")
	f := h.startFeed("a")
	for i, step := range []struct{ fromSession, from, direction, session, window string }{
		{session, root, "next", session, top},
		{session, child, "next", session, sibling},
		{session, sibling, "prev", session, child},
		{session, child, "prev", session, root},
		{session, grandchild, "prev", session, child},
		{session, grandchild, "next", session, grandSibling},
		{session, grandSibling, "prev", session, grandchild},
		{session, grandSibling, "next", session, top},
		{session, sibling, "next", session, top},
		{session, top, "next", otherSession, other},
		{otherSession, other, "prev", session, top},
		{otherSession, other, "next", session, root},
		{session, root, "prev", otherSession, other},
	} {
		h.in("switch-client", "-c", f.client, "-t", step.fromSession, ";", "select-window", "-t", step.from)
		f.send(fmt.Sprintf(`{"id":%d,"switch-window":{"direction":%q}}`, i, step.direction))
		f.waitReply(fmt.Sprintf(`{"reply":{"id":%d,"switched":{"session":%q,"window":%q}}}`, i, step.session, step.window))
		if got := h.in("display-message", "-p", "-c", f.client, "#{session_id} #{window_id}"); got != step.session+" "+step.window {
			t.Fatalf("switch-window %s from %s: %s, want %s %s", step.direction, step.from, got, step.session, step.window)
		}
	}
	h.markSubagent("a", "root")
	h.markSubagent("a", "top")
	h.in("set-option", "-p", "-t", "b:", "@kido_run", "other-run")
	f.send(`{"id":100,"switch-window":{"direction":"next"}}`)
	f.waitReply(`{"reply":{"id":100,"switched":null}}`)
}

func TestRpcProtocolRefusal(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	client := h.appClient("alpha")
	for _, stamp := range []string{"9.9", ""} {
		if stamp == "" {
			h.in("set-environment", "-gu", "KIDO_PROTOCOL")
		} else {
			h.in("set-environment", "-g", "KIDO_PROTOCOL", stamp)
		}
		cmd := feedCmd(h, "--server", h.stateDir, "--client", client)
		cmd.Stdin = strings.NewReader("")
		var out bytes.Buffer
		cmd.Stdout = &out
		done := make(chan error, 1)
		go func() { done <- cmd.Run() }()
		select {
		case err := <-done:
			ee, ok := err.(*exec.ExitError)
			if !ok || ee.ExitCode() != 2 {
				t.Fatalf("exit: %v", err)
			}
		case <-time.After(settle):
			cmd.Process.Kill()
			<-done
			t.Fatal("RPC refusal timed out")
		}
		server := "null"
		if stamp != "" {
			server = `"9.9"`
		}
		want := "{\"hello\":{\"protocol\":\"2.1\",\"server\":" + server + "}}\n{\"error\":\"server protocol does not match binary protocol\"}\n"
		if out.String() != want {
			t.Fatalf("refusal %q, want %q", out.String(), want)
		}
	}
}
