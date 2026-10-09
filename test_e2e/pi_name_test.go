package e2e

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestPiSessionNameEverywhere(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	root := h.firstPane("alpha")
	parentInbox := startInbox(t, "ok\n")
	h.programStatus(root, "state=idle:app=pi")
	h.agentStatus("name-root", root, "pi", "--name", "Parent", "--inbox", parentInbox.Path)
	pane := h.piPane("alpha", "launch - kido")
	h.programStatus(pane, "state=idle:app=pi")
	in := startInbox(t, "ok\n")
	h.agentRunMeta("name-child", pane, "launch", "name-root")
	report := func(name string) {
		h.agentStatus("name-child", pane, "pi", "--name", name, "--inbox", in.Path, "--parent-session", "name-root")
	}
	h.waitRow("Parent")
	f := h.startFeed("alpha")
	for _, name := range []string{"launch", "Renamed Agent"} {
		report(name)
		h.waitRow(name)
		h.waitFor(func() bool { return h.rowFor(name) == "└ "+name }, settle, msgf("exact child sidebar title %s (rows %v)", name, h.rows()))
		f.waitLast(func(s feedSnapshot) bool { return snapshotTitle(s, pane) == name }, "exact RPC child session name "+name)
		rows := h.listedRuns(root)
		if len(rows) != 1 || rows[0].Name != name || !rows[0].Named {
			t.Fatalf("list_runs name: %+v", rows)
		}
		h.expectKido(root, "hello", nil, "delivered to "+name+" by inbox", "tool", "message_agent", "@"+name)
		h.expectKido(root, "question", nil, "delivered to "+name+" by inbox", "tool", "ask_agent", "--id", "name-ask", name)
		h.expectKido(root, "correction", nil, "delivered to "+name+" by inbox", "tool", "steer_subagent", name)
		h.expectKido(root, "", nil, "interrupted "+name, "tool", "interrupt_subagent", name)
		h.expectKido(pane, "done", []string{"KIDO_AGENT_PARENT_SESSION=name-root", "KIDO_AGENT_RUN_ID=name-child"}, "delivered to Parent by inbox", "tool", "notify_parent")
		messages := envelopes(parentInbox)
		if got := field(messages[len(messages)-1], "from", "name"); got != name {
			t.Fatalf("notice sender name = %q, want %q", got, name)
		}
	}
	h.expectKido(root, "old name", nil, `kido tool message_agent: no agent session matches "launch"`, "tool", "message_agent", "launch")
	if out, rc := h.kidoAs(root, "", nil, "tool", "stop_run", "launch"); rc != 1 || !strings.Contains(out, "no run matches") {
		t.Fatalf("stop by stale launch name: %d %s", rc, out)
	}
	h.agentStatus("name-child", pane, "pi", "--name", "Renamed Agent", "--parent-session", "name-root")
	h.expectKido(root, "", nil, "kido tool stop_run: subagent Renamed Agent has no inbox to ask nicely over; pass --force to kill its window instead", "tool", "stop_run", "@Renamed Agent")
	report("Renamed Agent")
	if out, rc := h.kidoAs(pane, "", nil, "run-outcome", "--result", "completed", "--unreported", "name-child"); rc != 0 {
		t.Fatalf("ending: %d %s", rc, out)
	}
	last := envelopes(parentInbox)
	if got := last[len(last)-1]; !strings.Contains(field(got, "text"), `subagent "Renamed Agent"`) || field(got, "from", "name") != "Renamed Agent" {
		t.Fatalf("ending notice: %v", got)
	}
	if rows := h.listedRuns(root); rows[0].Name != "Renamed Agent" {
		t.Fatalf("ended but still live name: %+v", rows)
	}

	unnamed := h.piPane("alpha", "π - Unnamed - kido")
	h.agentStatus("unnamed-session", unnamed, "pi", "--name", "", "--inbox", in.Path)
	h.waitRow("π - Unnamed - kido")
	found := false
	for _, row := range h.listedRuns(root) {
		if row.ID == "unnamed-session" {
			found = true
			if row.Name != "π - Unnamed - kido" || row.Named {
				t.Fatalf("unnamed display/addressability: %+v", row)
			}
		}
	}
	if !found {
		t.Fatal("unnamed agent missing from list_runs")
	}
	h.expectKido(root, "not a name", nil, `kido tool message_agent: no agent session matches "\207\128 - Unnamed - kido"`, "tool", "message_agent", "π - Unnamed - kido")
	h.expectKido(root, "id works", nil, "delivered to π - Unnamed - kido by inbox", "tool", "message_agent", "unnamed-sess")
	h.agentStatus("unnamed-session", unnamed, "pi", "--name", "Asker", "--inbox", in.Path)
	if _, rc := askCommand(h, unnamed, "What next?", "tool", "ask_user", "--session-file", filepath.Join(h.dir, "session.json")); rc != 0 {
		t.Fatal("ask failed")
	}
	h.agentStatus("unnamed-session", unnamed, "pi", "--name", "New Asker", "--inbox", in.Path)
	if asks := openAsks(h, "unnamed-session"); len(asks) != 1 || asks[0].Name != "New Asker" {
		t.Fatalf("live ask name: %+v", asks)
	}
	f.waitLast(func(s feedSnapshot) bool { return len(s.Asks) == 1 && s.Asks[0].Name == "New Asker" }, "RPC ask rename")
	h.agentStatus("unnamed-session", unnamed, "pi", "--remove")
	if asks := openAsks(h, "unnamed-session"); asks[0].Name != "Asker" || !asks[0].Ended {
		t.Fatalf("ended ask stored name: %+v", asks)
	}
}
