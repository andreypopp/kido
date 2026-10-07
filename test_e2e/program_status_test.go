package e2e

import (
	"fmt"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
)

func TestProgramStatusSidebarAndRpc(t *testing.T) {
	t.Parallel()
	h := start(t, "status")
	ready := filepath.Join(t.TempDir(), "ready")
	pane := h.newWindow("status", "program", "sh", "-c", fmt.Sprintf(`stty -echo; printf ready > %s; while IFS= read -r line; do case "$line" in prompt) printf '\033]133;A\007';; *) printf '\033]7501;%%s\007' "$line";; esac; done`, shellQuote(ready)))
	h.waitFileNonEmpty(ready)
	emit := func(body string) {
		t.Helper()
		h.in("send-keys", "-t", pane, "-l", body)
		h.in("send-keys", "-t", pane, "Enter")
	}
	emit("state=working:app=builder:title=QnVpbGQ:msg=UGxhbg")
	h.waitRow("◼Build Plan")
	f := h.startFeed("status")
	find := func(s feedSnapshot) (feedRow, bool) {
		for _, session := range s.Sessions {
			for _, row := range feedItems(session.Nodes) {
				if row.ID == pane {
					return row, true
				}
			}
		}
		return feedRow{}, false
	}
	wait := func(state, indicator string, count int) feedRow {
		t.Helper()
		s := f.waitLast(func(s feedSnapshot) bool {
			r, ok := find(s)
			return ok && len(r.ProgramStatus.Records) == count && (count == 0 || r.ProgramStatus.Records[0].State == state) && (indicator == "" || r.Indicator != nil && r.Indicator.Kind == indicator)
		}, "program status "+state+" "+indicator)
		r, _ := find(s)
		return r
	}
	r := wait("working", "running", 1)
	if r.ProgramStatus.Serial == 0 || r.ProgramStatus.Records[0].Title != "Build" || r.ProgramStatus.Records[0].Msg != "Plan" || r.ProgramStatus.Records[0].App != "builder" {
		t.Fatalf("decoded records: %+v", r.ProgramStatus)
	}
	emit("state=blocked:app=builder:title=QnVpbGQ=:msg=UGxhbg==:kind=question")
	h.waitRow("◆Build Plan")
	wait("blocked", "waiting", 1)
	emit("state=working:app=builder:title=QnVpbGQ=")
	wait("working", "running", 1)
	emit("id=child:state=blocked:title=Q2hpbGQ=:msg=RGVjaWRl:kind=auth:progress=42")
	h.waitRow("◆Child Decide 42%")
	r = wait("working", "waiting", 2)
	child := r.ProgramStatus.Records[1]
	if child.ID != "child" || child.Kind != "auth" || child.Progress == nil || *child.Progress != 42 || child.App != "" {
		t.Fatalf("child record: %+v", child)
	}
	emit("id=child:state=error:title=Q2hpbGQ=:msg=RGVjaWRl")
	wait("working", "failed", 2)
	window := h.in("display-message", "-p", "-t", pane, "#{window_id}")
	h.in("switch-client", "-c", h.client, "-t", window)
	r = wait("working", "running", 2)
	if len(r.Title) != 1 || r.Title[0].Text != "Build" {
		t.Fatalf("acknowledged child hid working root: %+v", r)
	}
	h.waitRow("◼Build")
	h.in("switch-client", "-c", h.client, "-t", "status:0")
	f.waitLast(func(s feedSnapshot) bool { return s.Client.Pane != pane }, "leave working sibling")
	emit("id=child:state=error:title=Q2hpbGQ=:msg=RGVjaWRl")
	wait("working", "failed", 2)
	emit("id=child:state=clear")
	wait("working", "running", 1)
	emit("state=clear")
	wait("", "", 0)
	h.waitFor(func() bool { return !hasLine(h.rows(), "Build") }, settle, msgf("cleared sidebar"))
	emit("state=working:app=builder:title=QnVpbGQ=")
	wait("working", "running", 1)
	emit("prompt")
	wait("", "", 0)
	emit("state=done:app=builder:title=QnVpbGQ=:msg=UGxhbg==")
	h.waitRow("✓Build Plan")
	r = wait("done", "done", 1)
	serial := r.ProgramStatus.Serial
	h.in("switch-client", "-c", h.client, "-t", window)
	h.waitRow("╶ Build Plan")
	wait("done", "idle", 1)
	h.in("switch-client", "-c", f.client, "-t", "status:0")
	h.in("switch-client", "-c", h.client, "-t", "status:0")
	f.waitLast(func(s feedSnapshot) bool { return s.Client.Pane != pane }, "leave program")
	emit("state=done:app=builder:title=QnVpbGQ=:msg=UGxhbg==")
	r = wait("done", "done", 1)
	if r.ProgramStatus.Serial <= serial {
		t.Fatal("fresh completion did not advance serial")
	}
	h.waitRow("✓Build Plan")
	emit("state=error:app=builder:title=QnVpbGQ=:msg=UGxhbg==")
	wait("error", "failed", 1)
	h.waitRow("◼Build Plan")
	h.in("switch-client", "-c", h.client, "-t", window)
	wait("error", "idle", 1)
	h.waitRow("╶ Build Plan")
	h.in("switch-client", "-c", h.client, "-t", "status:0")
	f.waitLast(func(s feedSnapshot) bool { return s.Client.Pane != pane }, "leave error")
	emit("state=done:app=builder:title=QnVpbGQ=:msg=UGxhbg==")
	r = wait("done", "done", 1)
	serial = r.ProgramStatus.Serial
	h.in("switch-client", "-c", h.client, "-t", window)
	wait("done", "idle", 1)
	h.in("switch-client", "-c", h.client, "-t", "status:0")
	f.waitLast(func(s feedSnapshot) bool { return s.Client.Pane != pane }, "leave acknowledged completion")
	killed := ""
	for _, pid := range controlClientPIDs(h.inner) {
		parent, err := exec.Command("ps", "-o", "ppid=", "-p", pid).Output()
		if err != nil || strings.TrimSpace(string(parent)) != strconv.Itoa(f.cmd.Process.Pid) {
			continue
		}
		n, err := strconv.Atoi(pid)
		if err != nil {
			t.Fatal(err)
		}
		if err := syscall.Kill(n, syscall.SIGKILL); err != nil {
			t.Fatal(err)
		}
		killed = pid
	}
	if killed == "" {
		t.Fatal("RPC control child not found")
	}
	h.waitFor(func() bool {
		for _, pid := range controlClientPIDs(h.inner) {
			if pid == killed {
				continue
			}
			parent, err := exec.Command("ps", "-o", "ppid=", "-p", pid).Output()
			if err == nil && strings.TrimSpace(string(parent)) == strconv.Itoa(f.cmd.Process.Pid) {
				return true
			}
		}
		return false
	}, settle, msgf("RPC control reconnect"))
	f.mu.Lock()
	f.lines = nil
	f.mu.Unlock()
	h.in("rename-session", "-t", "status", "reconnected")
	f.waitLast(func(s feedSnapshot) bool {
		r, ok := find(s)
		return ok && len(s.Sessions) == 1 && s.Sessions[0].Name == "reconnected" && len(r.ProgramStatus.Records) == 1 && r.ProgramStatus.Serial == serial && r.Indicator != nil && r.Indicator.Kind == "idle"
	}, "acknowledged serial stays suppressed after reconnect")
	emit("state=done:app=builder:title=QnVpbGQ=:msg=UGxhbg==")
	r = wait("done", "done", 1)
	if r.ProgramStatus.Serial <= serial {
		t.Fatal("newer serial did not rearm after reconnect")
	}
	if out, rc := h.kidoAs(pane, "", nil, "agent-status", "--agent", "pi", "--session", "status-agent"); rc != 0 {
		t.Fatalf("identity: %d %s", rc, out)
	}
	h.waitRow("✓Build Plan")
	r = wait("done", "done", 1)
	if len(r.Title) != 1 || r.Title[0].Text != "Build" {
		t.Fatalf("terminal precedence: %+v", r)
	}
	h.agentStatus("status-agent", pane, "pi", "", "--remove")
	h.waitRow("✓Build Plan")
	h.in("kill-pane", "-t", pane)
	f.waitLast(func(s feedSnapshot) bool { _, ok := find(s); return !ok }, "pane records removed")
}
