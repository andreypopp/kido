package e2e

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

type listedRun struct {
	ID           string `json:"id"`
	Name         string `json:"name"`
	Kind         string `json:"kind"`
	Relationship string `json:"relationship"`
	Run          string `json:"run"`
	State        string `json:"state"`
	StartedAt    string `json:"startedAt"`
	Status       string `json:"status"`
	Activity     string `json:"activity"`
	CanReply     bool   `json:"canReply"`
	Outcome      *struct {
		Result string `json:"result"`
		Text   string `json:"text"`
	} `json:"outcome"`
}

func (h *harness) listedRuns(pane string) []listedRun {
	h.t.Helper()
	out, rc := h.kidoAs(pane, "", nil, "tool", "list_runs", "--json")
	var rows []listedRun
	if err := json.Unmarshal([]byte(out), &rows); err != nil || rc != 0 {
		h.t.Fatalf("list_runs: rc=%d %v %q", rc, err, out)
	}
	return rows
}

func TestListRunsPeersParentSiblingsAndOwnRuns(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	root := h.firstPane("alpha")
	h.asyncParent("alpha", "root-list")
	peer := h.newWindow("alpha", "", "sh", "-c", "exec sleep 300")
	h.agentStatus("peer-list", peer, "pi", "waiting", "--activity", "reviewing")
	child := func(id string) string {
		pane := h.newWindow("alpha", "", "sh", "-c", "exec sleep 300")
		h.agentStatus(id, pane, "pi", "running", "--parent-session", "root-list", "--inbox", startInbox(t, "ok\n").Path)
		h.agentRunMeta(id, pane, id, "root-list")
		return pane
	}
	first, second := child("first-list"), child("second-list")
	other := h.newWindow("alpha", "", "sh", "-c", "exec sleep 300")
	h.agentStatus("other-child", other, "pi", "idle", "--parent-session", "peer-list")
	h.agentRunMeta("other-child", other, "other-child", "peer-list")
	bash := h.asyncBash("root-job", "sleep", "300")
	out, rc := h.kidoAs(first, "", nil, "tool", "async_bash", "--name", "child-job", "--", "sleep 300")
	fields := strings.Fields(out)
	if rc != 0 || len(fields) != 4 {
		t.Fatalf("start child job = rc %d %q", rc, out)
	}
	childBash := fields[2]

	rows := h.listedRuns(root)
	seen := map[string]listedRun{}
	for _, row := range rows {
		seen[row.ID] = row
	}
	if len(seen) != 4 || seen["peer-list"].Relationship != "peer" || seen["peer-list"].Status != "waiting" || seen["peer-list"].Activity != "reviewing" {
		t.Fatalf("root rows = %+v, want one peer and three own runs", rows)
	}
	for _, id := range []string{"first-list", "second-list", bash} {
		r := seen[id]
		wantKind := "subagent"
		if id == bash {
			wantKind = "bash"
		}
		if r.Kind != wantKind || r.Relationship != "own" || r.Run != id || r.State != "running" || r.StartedAt == "" {
			t.Errorf("own row %s = %+v", id, r)
		}
	}
	for _, c := range []struct {
		pane, sibling string
		own           string
	}{{first, "second-list", childBash}, {second, "first-list", ""}} {
		rows = h.listedRuns(c.pane)
		seen = map[string]listedRun{}
		for _, row := range rows {
			seen[row.ID] = row
		}
		want := 2
		if c.own != "" {
			want++
		}
		if len(seen) != want || seen["root-list"].Relationship != "parent" || seen[c.sibling].Relationship != "peer" || seen[c.sibling].Kind != "subagent" {
			t.Errorf("child rows = %+v, want parent, live sibling and own jobs only", rows)
		}
		if c.own != "" && (seen[c.own].Kind != "bash" || seen[c.own].Relationship != "own") {
			t.Errorf("child own job = %+v", seen[c.own])
		}
	}
}

func TestStopRunTerminatesWrapperAndCommandWithoutPane(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	in := h.asyncParent("alpha", "root-stop-pid")
	pidFile := filepath.Join(h.dir, "command.pid")
	run := h.asyncBash("stop-pid", "sh", "-c", "echo $$ > "+shellQuote(pidFile)+"; exec sleep 300")
	command, err := strconv.Atoi(strings.TrimSpace(h.waitFileNonEmpty(pidFile)))
	if err != nil {
		t.Fatal(err)
	}
	metaBytes, err := os.ReadFile(filepath.Join(h.stateDir, "runs", run, "meta.json"))
	if err != nil {
		t.Fatal(err)
	}
	var meta struct {
		Pid int `json:"pid"`
	}
	if err := json.Unmarshal(metaBytes, &meta); err != nil {
		t.Fatal(err)
	}
	var record map[string]any
	if err := json.Unmarshal(metaBytes, &record); err != nil {
		t.Fatal(err)
	}
	record["pane"] = "%absent"
	metaBytes, _ = json.Marshal(record)
	if err := os.WriteFile(filepath.Join(h.stateDir, "runs", run, "meta.json"), metaBytes, 0o644); err != nil {
		t.Fatal(err)
	}
	out, rc := h.kidoAs(h.firstPane("alpha"), "", nil, "tool", "stop_run", run)
	if rc != 0 || !strings.Contains(out, "stopped async run") {
		t.Fatalf("stop_run = %d %q", rc, out)
	}
	h.waitFor(func() bool {
		return syscall.Kill(meta.Pid, 0) == syscall.ESRCH && syscall.Kill(command, 0) == syscall.ESRCH
	}, settle, msgf("wrapper and command to exit"))
	if info := h.runInfo(run); info.Outcome != "stopped" || info.OutcomeText != "stopped by its parent" {
		t.Errorf("outcome = %+v", info)
	}
	h.waitFor(func() bool { return len(in.Received()) == 1 }, time.Second*2, msgf("one stopping notice"))
}

func TestListRunsKeepsAllRunningAndNewestTwentyEnded(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	caller := h.firstPane("alpha")
	h.agentStatus("recent-root", caller, "pi", "idle")
	for i := 0; i < 24; i++ {
		id := fmt.Sprintf("recent-run-%02d", i)
		h.agentRunMeta(id, caller, id, "recent-root")
		if i >= 2 {
			outcome := []byte(`{"result":"completed","text":"done","at":"2023-11-14T22:13:20Z"}`)
			if err := os.WriteFile(filepath.Join(h.stateDir, "runs", id, "outcome"), outcome, 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}
	rows := h.listedRuns(caller)
	if len(rows) != 22 {
		t.Fatalf("list_runs returned %d rows, want all two running and twenty ended", len(rows))
	}
	for i, row := range rows {
		want := fmt.Sprintf("recent-run-%02d", 23-i)
		if i >= 20 {
			want = fmt.Sprintf("recent-run-%02d", 21-i)
		}
		if row.ID != want {
			t.Errorf("row %d id = %s, want %s", i, row.ID, want)
		}
		if i < 20 && (row.State != "ended" || row.Outcome == nil || row.Outcome.Result != "completed" || row.Outcome.Text != "done") {
			t.Errorf("ended row = %+v", row)
		}
		if i >= 20 && row.State != "running" {
			t.Errorf("running row = %+v", row)
		}
	}
}
