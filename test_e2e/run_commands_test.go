package e2e

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
)

type startedRun struct {
	ID     string `json:"id"`
	Pane   string `json:"pane"`
	Output string `json:"output"`
}

func (r startedRun) paneID() string {
	_, pane, _ := strings.Cut(r.Pane, ".")
	return pane
}

func (h *harness) startRun(pane string, args ...string) startedRun {
	h.t.Helper()
	out, rc := h.kidoAs(pane, "", nil, args...)
	if rc != 0 {
		h.t.Fatalf("kido %v: exit %d: %q", args, rc, out)
	}
	var r startedRun
	if err := json.Unmarshal([]byte(out), &r); err != nil {
		h.t.Fatalf("kido %v: %v (%q)", args, err, out)
	}
	if r.ID == "" || !strings.HasPrefix(r.Pane, "@") || !strings.Contains(r.Pane, ".") || r.Output == "" {
		h.t.Fatalf("kido %v printed %+v, want id, @WINDOW.PANE and output", args, r)
	}
	return r
}

func TestRunEndingsAndRefusals(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	caller := h.firstPane("alpha")

	r := h.startRun(caller, "run", "--name", "run-exit", "--", "sh", "-c", "exit 3")
	if want := filepath.Join(h.stateDir, "runs", r.ID, "output"); r.Output != want {
		t.Errorf("output = %q, want %q", r.Output, want)
	}
	if got := h.startCommand(h.windowID(r.paneID())); !strings.Contains(got, "exit 3") {
		t.Errorf("pane command = %q, want the run's own argv", got)
	}
	if out, rc := h.kidoAs(caller, "", nil, "run-wait", r.ID); rc != 0 || out != "failed" {
		t.Fatalf("run-wait = %d %q, want failed", rc, out)
	}
	out, rc := h.kidoAs(caller, "", nil, "run-wait", "--json", r.ID)
	if rc != 0 {
		t.Fatalf("run-wait --json: exit %d %q", rc, out)
	}
	var outcome struct {
		Result string `json:"result"`
		Text   string `json:"text"`
	}
	if err := json.Unmarshal([]byte(out), &outcome); err != nil || outcome.Result != "failed" || outcome.Text != "exit 3" {
		t.Fatalf("run-wait --json = %q (%v), want failed/exit 3", out, err)
	}
	h.reap("reap-run.out")
	info := h.runInfo(r.ID)
	if info.Outcome != "failed" || info.OutcomeText != "exit 3" {
		t.Fatalf("recorded run = %+v, want failed/exit 3", info)
	}
	if got := fmt.Sprint(h.runMeta("session-"+r.ID, r.ID)["session"]); got != "" {
		t.Errorf("a gone pane's session = %q, want empty", got)
	}

	sessionRun := h.startRun(caller, "run", "--name", "run-session", "--", "sleep", "300")
	if got := fmt.Sprint(h.runMeta("session-before", sessionRun.ID)["session"]); got != "" {
		t.Errorf("session before the option = %q, want empty", got)
	}
	h.in("set-option", "-p", "-t", sessionRun.paneID(), "@kido_session", "sess-abc")
	if got := fmt.Sprint(h.runMeta("session-during", sessionRun.ID)["session"]); got != "sess-abc" {
		t.Errorf("session with the option = %q, want sess-abc", got)
	}
	h.in("kill-pane", "-t", sessionRun.paneID())
	h.reap("reap-session.out")
	if got := fmt.Sprint(h.runMeta("session-after", sessionRun.ID)["session"]); got != "" {
		t.Errorf("session after the pane is gone = %q, want empty", got)
	}

	pidFile := filepath.Join(h.dir, "signalled.pid")
	signalled := h.startRun(caller, "run", "--name", "run-signal", "--", "sh", "-c",
		"echo $$ > "+shellQuote(pidFile)+"; exec sleep 300")
	pid, err := strconv.Atoi(strings.TrimSpace(h.waitFileNonEmpty(pidFile)))
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Kill(pid, syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	h.waitFor(func() bool { return h.paneDead(signalled.paneID()) }, settle,
		msgf("the signalled pane to die"))
	h.reap("reap-signal.out")
	info = h.waitOutcome(signalled.ID)
	if info.Outcome != "failed" || info.OutcomeText != "signal TERM" {
		t.Errorf("signalled run = %+v, want failed/signal TERM", info)
	}

	for _, c := range []struct {
		args []string
		code int
		want string
	}{
		{[]string{"run"}, 1, "required"},
		{[]string{"run", "--name", "no-command"}, 1, "no command given"},
		{[]string{"run", "--name", "bad$name", "--", "true"}, 4, `refusing window name "bad$name"`},
		{[]string{"run-child", "%999999", "--name", "gone-parent", "--", "true"}, 2, "pane %999999 is gone"},
		{[]string{"run-child", "no-such-parent", "--name", "gone-run", "--", "true"}, 2, "no run no-such-parent"},
		{[]string{"runs", "no-such-run"}, 3, `run "no-such-run": no such run`},
		{[]string{"run-wait", "no-such-run"}, 3, "run no-such-run has no meta"},
		{[]string{"run-stop", "no-such-run"}, 3, "run no-such-run: no such run"},
	} {
		if out, rc := h.kidoAs(caller, "", nil, c.args...); rc != c.code || !strings.Contains(out, c.want) {
			t.Errorf("kido %v = %d %q, want exit %d and %q", c.args, rc, out, c.code, c.want)
		}
	}
	if got := h.in("list-windows", "-a", "-F", "#{window_name}"); strings.Contains(got, "gone-parent") || strings.Contains(got, "gone-run") {
		t.Errorf("a refused run-child created a window: %q", got)
	}
}

func TestRunStopRecordsThenCloses(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	caller := h.firstPane("alpha")

	r := h.startRun(caller, "run", "--name", "run-stop", "--", "sleep", "300")
	if out, rc := h.kidoAs(caller, "", nil, "run-stop", r.ID); rc != 0 || !strings.Contains(out, "stopped run "+r.ID) {
		t.Fatalf("run-stop = %d %q, want a stop", rc, out)
	}
	if info := h.runInfo(r.ID); info.Outcome != "stopped" {
		t.Fatalf("run-stop outcome = %+v, want stopped", info)
	}
	h.waitFor(func() bool { return !h.paneExists(r.paneID()) }, settle, msgf("run-stop's pane to close"))
	if out, rc := h.kidoAs(caller, "", nil, "run-stop", r.ID); rc != 5 || !strings.Contains(out, "already ended") {
		t.Errorf("second run-stop = %d %q, want exit 5 and already ended", rc, out)
	}

	done := h.startRun(caller, "run", "--name", "run-done", "--", "sleep", "300")
	if out, rc := h.kidoAs(caller, "", nil, "run-stop", "--result", "completed", done.ID); rc != 0 {
		t.Fatalf("run-stop --result completed = %d %q", rc, out)
	}
	if info := h.runInfo(done.ID); info.Outcome != "completed" {
		t.Fatalf("completed stop outcome = %+v", info)
	}

	lonely := h.startRun(caller, "run", "--name", "run-lonely", "--", "sleep", "300")
	h.in("new-session", "-d", "-s", "lonely", "-c", h.dir, "sh", "-c", "exec sleep 300")
	first := h.in("list-windows", "-t", "lonely", "-F", "#{window_id}")
	h.in("move-window", "-s", h.windowID(lonely.paneID()), "-t", "lonely:")
	h.in("kill-window", "-t", first)
	out, rc := h.kidoAs(caller, "", nil, "run-stop", lonely.ID)
	if rc != 1 || !strings.Contains(out, "only pane") {
		t.Fatalf("run-stop in a session's only pane = %d %q, want exit 1 and the refusal", rc, out)
	}
	if info := h.runInfo(lonely.ID); info.Outcome != "stopped" {
		t.Errorf("refused pane's run = %+v, want recorded stopped", info)
	}
}

func TestRunChildUnderARunAndAPaneParent(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	caller := h.firstPane("alpha")
	h.programStatus(caller, "state=idle:app=pi", "parent")
	h.setPiOptions(caller, "parent-run", "Parent", "", "")
	callerPane := h.in("display-message", "-p", "-t", caller, "#{pane_id}")
	h.agentRunMeta("parent-run", callerPane, "Parent", "")

	byRun := h.startRun(caller, "run-child", "parent-run", "--name", "child-of-run", "--", "sleep", "300")
	byPane := h.startRun(caller, "run-child", callerPane, "--name", "child-of-pane", "--", "sleep", "300")
	for id, want := range map[string]string{byRun.ID: "parent-run", byPane.ID: callerPane} {
		if got := fmt.Sprint(h.runMeta("parent-"+id, id)["parent"]); got != want {
			t.Errorf("run %s parent = %q, want %q", id, got, want)
		}
	}

	out, rc := h.kidoAs(caller, "", nil, "runs", "--json", "--parent", callerPane)
	if rc != 0 {
		t.Fatalf("runs --parent %s: %d %q", callerPane, rc, out)
	}
	var paneRows []struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal([]byte(out), &paneRows); err != nil {
		t.Fatal(err)
	}
	if len(paneRows) != 1 || paneRows[0].ID != byPane.ID {
		t.Errorf("runs --parent %s = %+v, want only %s", callerPane, paneRows, byPane.ID)
	}

	if out, rc := h.kidoAs(caller, "", nil, "run-outcome", "--result", "completed", "--", "parent-run"); rc != 0 {
		t.Fatalf("ending the parent run: %d %q", rc, out)
	}
	h.programStatus(caller, "state=idle")
	h.reap("reap-child.out")
	for _, id := range []string{byRun.ID, byPane.ID} {
		info := h.runInfo(id)
		if info.Outcome != "failed" || info.OutcomeText != "its parent ended" {
			t.Errorf("orphan %s = %+v, want failed/its parent ended", id, info)
		}
	}

	out, rc = h.kidoAs(caller, "", nil, "runs", "--json", "--parent", "parent-run")
	if rc != 0 {
		t.Fatalf("runs --parent: %d %q", rc, out)
	}
	var rows []struct {
		ID     string `json:"id"`
		Parent string `json:"parent"`
	}
	if err := json.Unmarshal([]byte(out), &rows); err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].ID != byRun.ID || rows[0].Parent != "parent-run" {
		t.Errorf("runs --parent parent-run = %+v, want only %s", rows, byRun.ID)
	}
}
