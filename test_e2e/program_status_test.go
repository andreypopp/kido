package e2e

import (
	"encoding/base64"
	"fmt"
	"os"
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
	dir := t.TempDir()
	ready := filepath.Join(dir, "ready")
	longStatus := filepath.Join(dir, "long-status")
	pane := h.newWindow("status", "program", "sh", "-c", fmt.Sprintf(`stty -echo; printf '\033]2;Build\007'; printf ready > %s; while IFS= read -r line; do case "$line" in prompt) printf '\033]133;A\007';; long) cat %s;; *) printf '\033]7501;%%s\007' "$line";; esac; done`, shellQuote(ready), shellQuote(longStatus)))
	h.waitFileNonEmpty(ready)
	emit := func(body string) {
		t.Helper()
		h.in("send-keys", "-t", pane, "-l", body)
		h.in("send-keys", "-t", pane, "Enter")
	}
	emit("state=working:app=builder:title=QnVpbGQ:msg=UGxhbg")
	h.waitRow("◼Build Plan")
	f := h.startFeed("status")
	// report is the shell report's state, "Idle:success" or "Idle:failure" with an outcome,
	// "none" for no report, or "" for any.
	report := func(r feedRow) string {
		rep := r.Lifecycle.Shell.Report
		switch {
		case rep == nil:
			return "none"
		case rep.Outcome != nil:
			return rep.State + ":" + feedValue(rep.Outcome.Result)
		}
		return rep.State
	}
	wait := func(state, want string, count int) feedRow {
		t.Helper()
		s := f.waitLast(func(s feedSnapshot) bool {
			r, ok := feedRowFor(s, pane)
			return ok && r.isShell() && len(r.ProgramStatus.Records) == count && (count == 0 || r.ProgramStatus.Records[0].State == state) && (want == "" || report(r) == want)
		}, "program status "+state+" "+want)
		r, _ := feedRowFor(s, pane)
		return r
	}
	outcomeSerial := func(r feedRow) int { return feedValue(r.Lifecycle.Shell.Report.Outcome.Serial) }
	r := wait("working", "Running", 1)
	if r.ProgramStatus.Serial == 0 || r.ProgramStatus.Records[0].Title != "Build" || r.ProgramStatus.Records[0].Msg != "Plan" || r.ProgramStatus.Records[0].App != "builder" {
		t.Fatalf("decoded records: %+v", r.ProgramStatus)
	}
	msg := strings.Repeat("long message ", 125)
	if err := os.WriteFile(longStatus, []byte("\x1b]7501;state=working:app=builder:title=QnVpbGQ=:msg="+base64.StdEncoding.EncodeToString([]byte(msg))+"\a"), 0600); err != nil {
		t.Fatal(err)
	}
	emit("long")
	f.waitLast(func(s feedSnapshot) bool {
		r, ok := feedRowFor(s, pane)
		return ok && len(r.ProgramStatus.Records) == 1 && r.ProgramStatus.Records[0].Msg == msg
	}, "1500-byte program status message")
	emit("state=blocked:app=builder:title=QnVpbGQ=:msg=UGxhbg==:kind=question")
	h.waitRow("◆Build Plan")
	r = wait("blocked", "Waiting", 1)
	if k := r.Lifecycle.Shell.Report.Kind; k == nil || *k != "question" {
		t.Fatalf("blocked kind: %s", f.last().raw)
	}
	emit("state=working:app=builder:title=QnVpbGQ=")
	wait("working", "Running", 1)
	emit("id=child:state=blocked:title=Q2hpbGQ=:msg=RGVjaWRl:kind=auth:progress=42")
	h.waitRow("◆Child Decide 42%")
	r = wait("working", "Waiting", 2)
	child := r.ProgramStatus.Records[1]
	if child.ID != "child" || child.Kind != "auth" || child.Progress == nil || *child.Progress != 42 || child.App != "" {
		t.Fatalf("child record: %+v", child)
	}
	// A child's error while the root still works is a pending outcome: the report runs.
	emit("id=child:state=error:title=Q2hpbGQ=:msg=RGVjaWRl")
	wait("working", "Running", 2)
	window := h.in("display-message", "-p", "-t", pane, "#{window_id}")
	h.in("switch-client", "-c", h.client, "-t", window)
	r = wait("working", "Running", 2)
	if r.Title != "Build" {
		t.Fatalf("the child's error hid the working root's title: %+v", r)
	}
	h.waitRow("◼Build")
	h.in("switch-client", "-c", h.client, "-t", "status:0")
	f.waitLast(func(s feedSnapshot) bool { return s.Client.Pane != pane }, "leave working sibling")
	emit("id=child:state=error:title=Q2hpbGQ=:msg=RGVjaWRl")
	wait("working", "Running", 2)
	emit("id=child:state=clear")
	wait("working", "Running", 1)
	// The pending error survives the empty record set once nothing works.
	emit("state=clear")
	wait("", "Idle:failure", 0)
	h.waitFor(func() bool { return !hasLine(h.rows(), "Build") }, settle, msgf("cleared sidebar"))
	emit("state=working:app=builder:title=QnVpbGQ=")
	wait("working", "Running", 1)
	emit("prompt")
	wait("", "none", 0)
	emit("state=done:app=builder:title=QnVpbGQ=:msg=UGxhbg==")
	h.waitRow("✓Build Plan")
	r = wait("done", "Idle:success", 1)
	serial, raw := outcomeSerial(r), r.ProgramStatus.Serial
	// A visit acknowledges in the TUI only; the feed keeps the outcome.
	h.in("switch-client", "-c", h.client, "-t", window)
	h.waitRow("╶ Build Plan")
	wait("done", "Idle:success", 1)
	h.in("switch-client", "-c", h.client, "-t", "status:0")
	// Re-reporting done with a new message is not a new outcome: its serial and the TUI's seen state hold.
	emit("state=done:app=builder:title=QnVpbGQ=:msg=UGxhbjI=")
	r, _ = feedRowFor(f.waitLast(func(s feedSnapshot) bool {
		r, ok := feedRowFor(s, pane)
		return ok && r.ProgramStatus.Serial > raw
	}, "the re-reported done's raw serial"), pane)
	if report(r) != "Idle:success" || outcomeSerial(r) != serial {
		t.Fatalf("an unchanged done re-armed: %+v", r.Lifecycle.Shell.Report.Outcome)
	}
	h.waitRow("╶ Build Plan2")
	emit("state=error:app=builder:title=QnVpbGQ=:msg=UGxhbg==")
	r = wait("error", "Idle:failure", 1)
	if outcomeSerial(r) <= serial {
		t.Fatal("done -> error did not advance the outcome serial")
	}
	h.waitRow("◼Build Plan")
	h.in("switch-client", "-c", h.client, "-t", window)
	h.waitRow("╶ Build Plan")
	wait("error", "Idle:failure", 1)
	h.in("switch-client", "-c", h.client, "-t", "status:0")
	emit("state=done:app=builder:title=QnVpbGQ=:msg=UGxhbg==")
	r = wait("done", "Idle:success", 1)
	serial = outcomeSerial(r)
	h.waitRow("✓Build Plan")
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
		r, ok := feedRowFor(s, pane)
		return ok && len(s.Sessions) == 1 && s.Sessions[0].Name == "reconnected" && len(r.ProgramStatus.Records) == 1 && report(r) == "Idle:success" && outcomeSerial(r) == serial
	}, "the same server keeps the outcome's serial across a control reconnect")
	emit("state=error:app=builder:title=QnVpbGQ=:msg=UGxhbg==")
	wait("error", "Idle:failure", 1)
	emit("state=done:app=builder:title=QnVpbGQ=:msg=UGxhbg==")
	r = wait("done", "Idle:success", 1)
	if outcomeSerial(r) <= serial {
		t.Fatal("a new outcome after reconnect kept the old serial")
	}
	h.agentStatus("status-agent", pane)
	h.waitRow("✓Build Plan")
	r = wait("done", "Idle:success", 1)
	if r.Title != "Build" {
		t.Fatalf("terminal precedence: %+v", r)
	}
	h.clearPiOptions(pane)
	h.waitRow("✓Build Plan")
	h.in("kill-pane", "-t", pane)
	f.waitLast(func(s feedSnapshot) bool { _, ok := feedRowFor(s, pane); return !ok }, "pane records removed")
}
