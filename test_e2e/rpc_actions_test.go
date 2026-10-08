package e2e

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
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
		`"activate-ask":"../bad"`, `"delete-ask":true`, `"release-side-focus":false`,
		`"release-side-focus":true,"delete-ask":"A1"`,
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

func TestRpcAskActivateReviveDeleteExplicitSocket(t *testing.T) {
	t.Parallel()
	fakeDir := t.TempDir()
	output := filepath.Join(fakeDir, "revived")
	fake := fmt.Sprintf("#!/bin/sh\nprintf '%%s\\n' \"$PWD\" \"$@\" > %s\nexec sleep 300\n", shellQuote(output))
	if err := os.WriteFile(filepath.Join(fakeDir, "pi"), []byte(fake), 0o755); err != nil {
		t.Fatal(err)
	}
	h := startPathPrefix(t, "alpha", fakeDir)
	pane := h.newWindow("alpha", "asker", "sh", "-c", "exec sleep 300")
	in := startInbox(t, "ok\n")
	h.programStatus(pane, "state=idle:app=pi", "Decider")
	h.agentStatus("rpc-asker", pane, "pi", "--inbox", in.Path)
	file := filepath.Join(h.dir, "saved.jsonl")
	if err := os.WriteFile(file, []byte("saved session"), 0o600); err != nil {
		t.Fatal(err)
	}
	id, code := askCommand(h, pane, "Ship?\nSecond line", "tool", "ask_user", "--session-file", file)
	if code != 0 {
		t.Fatal(id)
	}
	f := h.startFeed("alpha", "PATH="+fakeDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	s := f.waitLast(func(s feedSnapshot) bool { return len(s.Asks) == 1 && s.Asks[0].ID == id && s.Asks[0].Pane != nil }, "live ask")
	a := s.Asks[0]
	if a.Session != "rpc-asker" || a.Name != "Decider" || a.Text != "Ship?\nSecond line" || *a.Pane != pane || a.Ended || a.Revivable {
		t.Fatalf("ask snapshot: %s", s.raw)
	}
	if _, err := time.Parse(time.RFC3339Nano, a.Created); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(s.raw, "sessionFile") || strings.Contains(s.raw, "\"cwd\"") {
		t.Fatalf("persistence leaked: %s", s.raw)
	}
	session := h.in("display-message", "-p", "-t", pane, "#{session_id}")
	window := h.in("display-message", "-p", "-t", pane, "#{window_id}")
	f.send(fmt.Sprintf(`{"id":1,"activate-ask":%q}`, id))
	f.waitReply(fmt.Sprintf(`{"reply":{"id":1,"activated":{"session":%q,"window":%q,"pane":%q}}}`, session, window, pane))
	h.agentStatus("rpc-asker", pane, "pi", "--remove")
	f.waitLast(func(s feedSnapshot) bool {
		return len(s.Asks) == 1 && s.Asks[0].Ended && s.Asks[0].Revivable && s.Asks[0].Pane == nil
	}, "revivable ask")
	if err := os.Remove(file); err != nil {
		t.Fatal(err)
	}
	f.waitLast(func(s feedSnapshot) bool { return len(s.Asks) == 1 && !s.Asks[0].Revivable }, "missing file changes snapshot")
	before := h.in("list-windows", "-a", "-F", "#{window_id}")
	f.send(fmt.Sprintf(`{"id":2,"activate-ask":%q}`, id))
	f.waitReply(fmt.Sprintf(`{"reply":{"id":2,"error":%q}}`, "pi session file is gone: "+file))
	if got := h.in("list-windows", "-a", "-F", "#{window_id}"); got != before {
		t.Fatal("failed revival created window")
	}
	if err := os.WriteFile(file, []byte("saved session"), 0o600); err != nil {
		t.Fatal(err)
	}
	f.send(fmt.Sprintf(`{"id":3,"activate-ask":%q}`, id))
	h.waitFor(func() bool {
		f.mu.Lock()
		defer f.mu.Unlock()
		for _, s := range f.lines {
			if strings.HasPrefix(s.raw, `{"reply":{"id":3,`) {
				if strings.Contains(s.raw, `"error"`) {
					t.Fatalf("revival: %s", s.raw)
				}
				return true
			}
		}
		return false
	}, settle, msgf("revival reply"))
	got := h.waitFileNonEmpty(output)
	if !strings.HasSuffix(got, "\n--session\n"+file+"\n") {
		t.Fatalf("revived arguments: %q", got)
	}
	newWindow := h.in("display-message", "-p", "-t", "alpha:ask-"+id, "#{window_id}")
	newPane := h.in("display-message", "-p", "-t", newWindow, "#{pane_id}")
	f.waitReply(fmt.Sprintf(`{"reply":{"id":3,"activated":{"session":%q,"window":%q,"pane":%q}}}`, session, newWindow, newPane))
	if newPane == pane {
		t.Fatal("revival reused old pane")
	}
	h.programStatus(newPane, "state=idle:app=pi", "Revived")
	h.agentStatus("rpc-asker", newPane, "pi", "--inbox", in.Path)
	f.waitLast(func(s feedSnapshot) bool {
		return len(s.Asks) == 1 && s.Asks[0].Pane != nil && *s.Asks[0].Pane == newPane && !s.Asks[0].Ended
	}, "revived holder")
	messages := len(in.Received())
	f.send(fmt.Sprintf(`{"id":4,"delete-ask":%q}`, id))
	f.waitReply(`{"reply":{"id":4,"deleted":true}}`)
	f.waitLast(func(s feedSnapshot) bool { return s.V == 2 && len(s.Asks) == 0 }, "ask removed")
	h.waitFor(func() bool { return len(in.Received()) == messages+1 }, settle, func() string { return fmt.Sprintf("removal notice; received %q", in.Received()) })
	if env, ok := parseEnvelope(in.Received()[messages]); !ok || env.Kind != "asks" || env.Text != "The user removed ask "+id+": Ship?" {
		t.Fatalf("removal note: %q", in.Received())
	}
	f.send(fmt.Sprintf(`{"id":5,"activate-ask":%q}`, id))
	f.waitReply(fmt.Sprintf(`{"reply":{"id":5,"error":%q}}`, "no ask "+id))
	f.send(fmt.Sprintf(`{"id":6,"delete-ask":%q}`, id))
	f.waitReply(fmt.Sprintf(`{"reply":{"id":6,"error":%q}}`, "no ask "+id))
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
	origin := h.in("new-window", "-P", "-F", "#{pane_id}", "-t", "two:", "-c", cwd, "exec sleep 300")
	session := h.in("display-message", "-p", "-t", origin, "#{session_id}")
	f := h.startFeed("one")
	f.waitLast(func(s feedSnapshot) bool { return len(s.Sessions) == 2 }, "sessions")
	f.send(fmt.Sprintf(`{"id":71,"new-window":%q}`, session))
	createdSession, window, pane := f.waitLocationReply(71, "created")
	if createdSession != session {
		t.Fatalf("new-window session: %s", createdSession)
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
	f.send(`{"id":73,"new-window":"$999999"}`)
	f.waitReply(`{"reply":{"id":73,"error":"no such session"}}`)
	for i, request := range []string{`"new-window":"two"`, `"new-session":false`, `"new-session":true,"new-window":"$0"`} {
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
	h.in("select-window", "-t", session+":"+window)
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
