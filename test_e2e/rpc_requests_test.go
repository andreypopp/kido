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
	waitLine(`{"hello":{"protocol":"1.1"}}`)
	f.mu.Lock()
	first := f.lines[0].raw
	f.mu.Unlock()
	if first != `{"hello":{"protocol":"1.1"}}` {
		t.Fatalf("first line: %s", first)
	}
	f.send(`{"id":1,"switch-window":{"direction":"next"}}`)
	waitLine(`{"reply":{"id":1,"switched":null}}`)
	f.send(`{"id":2,"unknown":true}`)
	waitLine(`{"reply":{"id":2,"error":"invalid or unknown request"}}`)
	f.send(`{"id":3,"switch-window":{"direction":"sideways"}}`)
	waitLine(`{"reply":{"id":3,"error":"invalid or unknown request"}}`)
	h.newWindow("alpha", "second")
	session := h.in("display-message", "-p", "-t", "alpha:", "#{session_id}")
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
	f.waitLast(func(s feedSnapshot) bool { return s.Filter == "nothing-matches" }, "filter set")
	f.send(`{"filter":""}`)
	f.waitLast(func(s feedSnapshot) bool { return s.Filter == "" && len(s.Sessions) == 1 }, "filter cleared")
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
		want := "{\"hello\":{\"protocol\":\"1.1\",\"server\":" + server + "}}\n{\"error\":\"server protocol does not match binary protocol\"}\n"
		if out.String() != want {
			t.Fatalf("refusal %q, want %q", out.String(), want)
		}
	}
}
