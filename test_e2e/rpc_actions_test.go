package e2e

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

func (f *feed) waitReply(want string) {
	f.h.t.Helper()
	f.h.waitFor(func() bool {
		f.mu.Lock()
		defer f.mu.Unlock()
		for _, s := range f.lines {
			if s.raw == want {
				return true
			}
		}
		return false
	}, settle, func() string { return fmt.Sprintf("outside-tmux RPC reply %s; last %s", want, f.last().raw) })
}

func TestRpcJumpExplicitSocket(t *testing.T) {
	t.Parallel()
	h := start(t, "one")
	h.newSession("two")
	f := h.startFeed("one")
	f.waitLast(func(s feedSnapshot) bool { return len(s.Sessions) == 2 }, "both sessions")
	window := h.in("display-message", "-p", "-t", "one:", "#{window_id}")
	pane := h.in("display-message", "-p", "-t", "one:", "#{pane_id}")
	session := h.in("display-message", "-p", "-t", "two:", "#{session_id}")
	h.in("link-window", "-s", window, "-t", "two:")
	f.send(fmt.Sprintf(`{"id":21,"jump":{"session":%q,"window":%q,"pane":%q}}`, session, window, pane))
	f.waitReply(fmt.Sprintf(`{"reply":{"id":21,"jumped":{"session":%q,"window":%q,"pane":%q}}}`, session, window, pane))
	if got := h.in("display-message", "-p", "-c", f.client, "#{session_id} #{window_id} #{pane_id}"); got != session+" "+window+" "+pane {
		t.Fatalf("jump = %s", got)
	}
	f.waitLast(func(s feedSnapshot) bool { return s.Client.Session == session && s.Client.Pane == pane }, "linked location")
	f.send(fmt.Sprintf(`{"id":22,"jump":{"session":%q,"window":"@999999","pane":%q}}`, session, pane))
	f.waitReply(`{"reply":{"id":22,"error":"no such pane in session/window"}}`)
	if got := h.in("display-message", "-p", "-c", f.client, "#{session_id} #{window_id} #{pane_id}"); got != session+" "+window+" "+pane {
		t.Fatalf("failed jump changed location: %s", got)
	}
	for i, request := range []string{
		`"jump":{"session":"one","window":"@0","pane":"%0"}`,
		`"release-side-focus":false`,
		`"no-such-request":true`,
	} {
		f.send(fmt.Sprintf(`{"id":%d,%s}`, 30+i, request))
		f.waitReply(fmt.Sprintf(`{"reply":{"id":%d,"error":"invalid or unknown request"}}`, 30+i))
	}
}

func TestRpcReleaseSideFocusExplicitSocket(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	f := h.startFeed("alpha")
	f.waitLast(func(s feedSnapshot) bool { return s.V == 2 }, "snapshot")
	h.in("refresh-client", "-t", f.client, "-f", "side-status-focus")
	if flags := h.in("display-message", "-p", "-c", f.client, "#{client_flags}"); !strings.Contains(flags, "side-status-focus") {
		t.Fatalf("focus setup: %s", flags)
	}
	f.send(`{"id":1,"release-side-focus":true}`)
	f.waitReply(`{"reply":{"id":1,"released":true}}`)
	if flags := h.in("display-message", "-p", "-c", f.client, "#{client_flags}"); strings.Contains(flags, "side-status-focus") {
		t.Fatalf("focus retained: %s", flags)
	}
}

func (f *feed) waitLocationReply(id int, key string) (session, window, pane string) {
	f.h.t.Helper()
	f.h.waitFor(func() bool {
		f.mu.Lock()
		defer f.mu.Unlock()
		for _, line := range f.lines {
			var event struct {
				Reply struct {
					ID                int    `json:"id"`
					Error             string `json:"error"`
					Created, Selected struct{ Session, Window, Pane string }
				} `json:"reply"`
			}
			if json.Unmarshal([]byte(line.raw), &event) != nil || event.Reply.ID != id {
				continue
			}
			if event.Reply.Error != "" {
				f.h.t.Fatalf("request %d: %s", id, event.Reply.Error)
			}
			target := event.Reply.Created
			if key == "selected" {
				target = event.Reply.Selected
			}
			session, window, pane = target.Session, target.Window, target.Pane
			return session != "" && window != "" && pane != ""
		}
		return false
	}, settle, msgf("location reply %d", id))
	f.waitReply(fmt.Sprintf(`{"reply":{"id":%d,%q:{"session":%q,"window":%q,"pane":%q}}}`, id, key, session, window, pane))
	return
}

func TestRpcCreateExplicitSocket(t *testing.T) {
	t.Parallel()
	h := start(t, "one")
	h.newSession("two")
	cwd, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	h.in("set-option", "-g", "default-command", "exec sleep 300")
	first := h.in("display-message", "-p", "-t", "two:", "#{window_id}")
	origin := h.in("new-window", "-P", "-F", "#{window_id}", "-t", "two:", "exec sleep 300")
	active := h.in("split-window", "-P", "-F", "#{pane_id}", "-t", origin, "-c", cwd, "exec sleep 300")
	h.in("select-pane", "-t", active)
	last := h.in("new-window", "-P", "-F", "#{window_id}", "-t", "two:", "exec sleep 300")
	session := h.in("display-message", "-p", "-t", origin, "#{session_id}")
	f := h.startFeed("one")
	f.waitLast(func(s feedSnapshot) bool { return len(s.Sessions) == 2 }, "sessions")
	f.send(fmt.Sprintf(`{"id":71,"new-window":%q}`, origin))
	createdSession, window, pane := f.waitLocationReply(71, "created")
	if createdSession != session {
		t.Fatalf("new-window session: %s", createdSession)
	}
	if got := h.in("list-windows", "-t", session, "-F", "#{window_id}"); got != strings.Join([]string{first, origin, window, last}, "\n") {
		t.Fatalf("window index order: %s", got)
	}
	if got := h.in("display-message", "-p", "-t", pane, "#{pane_current_path}"); got != cwd {
		t.Fatalf("cwd: %s", got)
	}
	if got := h.in("display-message", "-p", "-t", pane, "#{pane_start_command}"); got != `"exec sleep 300"` {
		t.Fatalf("default command: %s", got)
	}
	if got := h.in("display-message", "-p", "-c", f.client, "#{session_id} #{window_id} #{pane_id}"); got != session+" "+window+" "+pane {
		t.Fatalf("creation selection: %s", got)
	}
	f.send(`{"id":72,"new-session":true}`)
	newSession, newWindow, newPane := f.waitLocationReply(72, "created")
	if newSession == session || newWindow == window || newPane == pane {
		t.Fatal("session not created")
	}
	if got := h.in("display-message", "-p", "-t", newPane, "#{pane_current_path}"); got != cwd {
		t.Fatalf("session cwd: %s", got)
	}
	f.waitLast(func(s feedSnapshot) bool { return s.Client.Session == newSession && s.Client.Pane == newPane }, "created session snapshot")
	before := h.in("list-panes", "-a", "-F", "#{session_id}:#{window_id}:#{pane_id}")
	f.send(`{"id":73,"new-window":"@999999"}`)
	f.waitReply(`{"reply":{"id":73,"error":"no such window"}}`)
	for i, request := range []string{`"new-window":"two"`, `"new-session":false`, `"new-session":true,"new-window":"@0"`, `"new-window":"$0"`} {
		f.send(fmt.Sprintf(`{"id":%d,%s}`, 74+i, request))
		f.waitReply(fmt.Sprintf(`{"reply":{"id":%d,"error":"invalid or unknown request"}}`, 74+i))
	}
	if got := h.in("list-panes", "-a", "-F", "#{session_id}:#{window_id}:#{pane_id}"); got != before {
		t.Fatal("invalid creation had effects")
	}
}

func TestRpcSelectExplicitSocket(t *testing.T) {
	t.Parallel()
	h := start(t, "one")
	h.newSession("two")
	window := h.in("display-message", "-p", "-t", "one:", "#{window_id}")
	pane := h.in("split-window", "-d", "-P", "-F", "#{pane_id}", "-t", window, "exec sleep 300")
	h.in("select-pane", "-t", pane)
	session := h.in("display-message", "-p", "-t", "two:", "#{session_id}")
	h.in("link-window", "-s", window, "-t", "two:")
	h.in("select-window", "-t", "two:0")
	f := h.startFeed("one")
	f.waitLast(func(s feedSnapshot) bool { return len(s.Sessions) == 2 }, "sessions")
	f.send(fmt.Sprintf(`{"id":81,"select-window":{"session":%q,"window":%q}}`, session, window))
	s, w, p := f.waitLocationReply(81, "selected")
	if s != session || w != window || p != pane {
		t.Fatalf("select: %s %s %s", s, w, p)
	}
	f.send(fmt.Sprintf(`{"id":82,"select-session":%q}`, session))
	f.waitLocationReply(82, "selected")
	f.send(fmt.Sprintf(`{"id":83,"select-window":{"session":%q,"window":"@999999"}}`, session))
	f.waitReply(`{"reply":{"id":83,"error":"no such window in session"}}`)
	for i, request := range []string{`"select-window":{"session":"two","window":"@0"}`, `"select-window":{"session":"$0","window":"@0","pane":"%0"}`, `"select-session":"two"`, `"select-session":"$999999"`} {
		f.send(fmt.Sprintf(`{"id":%d,%s}`, 84+i, request))
		if i < 3 {
			f.waitReply(fmt.Sprintf(`{"reply":{"id":%d,"error":"invalid or unknown request"}}`, 84+i))
		} else {
			f.waitReply(`{"reply":{"id":87,"error":"no such window in session"}}`)
		}
	}
	if got := h.in("display-message", "-p", "-c", f.client, "#{session_id} #{window_id} #{pane_id}"); got != session+" "+window+" "+pane {
		t.Fatalf("selection changed: %s", got)
	}
}
