package e2e

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type userAsk struct {
	ID      string `json:"id"`
	Session string `json:"session"`
	Name    string `json:"name"`
	Text    string `json:"text"`
	Created string `json:"created"`
	Ended   bool   `json:"ended"`
}

func openAsks(h *harness, session string) []userAsk {
	h.t.Helper()
	args := []string{"get-asks"}
	if session != "" {
		args = append(args, "--session", session)
	}
	out, code := h.kidoAs("", "", nil, args...)
	var asks []userAsk
	if code != 0 || json.Unmarshal([]byte(out), &asks) != nil {
		h.t.Fatalf("get-asks: exit %d, %s", code, out)
	}
	return asks
}

func TestAskUserLifecycle(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.in("display-message", "-p", "-t", "alpha:", "#{pane_id}")
	h.programStatus(pane, "state=idle:app=pi", "Orchestrator")
	h.agentStatus("ask-session", pane)
	id, code := h.kidoAs(pane, "Ship now?\nOr wait?", nil, "tool", "ask_user")
	if code != 0 || !strings.HasPrefix(id, "A") || len(id) > 10 {
		t.Fatalf("ask_user: exit %d, %s", code, id)
	}
	asks := openAsks(h, "ask-session")
	if len(asks) != 1 || asks[0].ID != id || asks[0].Text != "Ship now?\nOr wait?" || asks[0].Name != "Orchestrator" || asks[0].Ended {
		t.Fatalf("ask: %+v", asks)
	}
	first := asks[0]
	other, code := h.kidoAs(pane, "Choose the colour?", nil, "tool", "ask_user")
	if code != 0 || other == id || len(openAsks(h, "")) != 2 {
		t.Fatalf("second ask: exit %d, %s", code, other)
	}
	if got := openAsks(h, "no-session"); len(got) != 0 {
		t.Fatalf("session filter: %+v", got)
	}
	h.programStatus(pane, "state=idle:app=pi", "Renamed")
	h.agentStatus("ask-session", pane)
	out, code := h.kidoAs(pane, "Ship Monday?", nil, "tool", "ask_user", "--replaces", id)
	asks = openAsks(h, "ask-session")
	if code != 0 || out != id || len(asks) != 2 || asks[1].ID != id || asks[1].Text != "Ship Monday?" || asks[1].Name != "Renamed" || asks[1].Created == first.Created {
		t.Fatalf("replacement: exit %d, %s, %+v", code, out, asks)
	}
	out, code = h.kidoAs(pane, "Missing", nil, "tool", "ask_user", "--replaces", "A1")
	if code != 1 || !strings.Contains(out, "no ask A1") {
		t.Fatalf("missing replace: exit %d, %s", code, out)
	}
	h.agentStatus("ask-session", pane, "--remove")
	asks = openAsks(h, "ask-session")
	if len(asks) != 2 || !asks[0].Ended || !asks[1].Ended {
		t.Fatalf("asks did not persist as ended: %+v", asks)
	}
	stored, err := os.ReadFile(filepath.Join(h.stateDir, "asks", id+".json"))
	if err != nil || strings.Contains(string(stored), "ended") {
		t.Fatalf("ended was persisted: %s, %v", stored, err)
	}
	h.programStatus(pane, "state=idle:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", pane, "#{pane_title}"), "π - "))
	h.agentStatus("ask-session", pane)
	if openAsks(h, "ask-session")[0].Ended {
		t.Fatal("resumed session still ended")
	}
	for _, ask := range []string{id, other} {
		out, code = h.kidoAs("", "", nil, "tool", "remove_ask", ask)
		if code != 0 {
			t.Fatalf("remove: exit %d, %s", code, out)
		}
	}
	if len(openAsks(h, "")) != 0 {
		t.Fatal("asks not removed")
	}
	task := filepath.Join(h.dir, "child-task")
	if err := os.WriteFile(task, []byte("do work"), 0o600); err != nil {
		t.Fatal(err)
	}
	spawn, code := h.kidoAs(pane, "", nil, "tool", "spawn_subagent", "--name", "asking-child", "--task-file", task, "--", "sh", "-c", "exec sleep 300")
	fields := strings.Fields(spawn)
	if code != 0 || len(fields) != 3 {
		t.Fatalf("spawn child: exit %d, %s", code, spawn)
	}
	h.programStatus(fields[1], "state=idle:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", fields[1], "#{pane_title}"), "π - "))
	h.agentStatus(fields[2], fields[1])
	for _, args := range [][]string{{"tool", "ask_user"}, {"tool", "remove_ask", id}} {
		out, code = h.kidoAs(fields[1], "Question", nil, args...)
		if code != 1 || !strings.Contains(out, "top-level agents only") {
			t.Fatalf("subagent refusal: exit %d, %s", code, out)
		}
	}
	h.programStatus(fields[1], "state=idle:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", fields[1], "#{pane_title}"), "π - "))
	h.agentStatus("nested-session", fields[1])
	nested, code := h.kidoAs(fields[1], "Nested root question", nil, "tool", "ask_user")
	if code != 0 {
		t.Fatalf("nested root was mistaken for its pane's run: exit %d, %s", code, nested)
	}
	out, code = h.kidoAs(fields[1], "", nil, "tool", "remove_ask", nested)
	if code != 0 {
		t.Fatalf("nested root remove: exit %d, %s", code, out)
	}
}

// A headless pi in an agent's pane reports after the agent, so it is the
// pane's latest record; the agent's own ask_user still names the agent,
// since the caller is the session pi names, not whoever reported the pane.
func TestAskNamesTheCallingSessionNotThePane(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.in("display-message", "-p", "-t", "alpha:", "#{pane_id}")
	h.programStatus(pane, "state=idle:app=pi", "Agent")
	h.agentStatus("agent-session", pane)
	agent := h.caller(pane)
	h.agentStatus("headless-session", pane)
	if id, code := h.kidoAs(pane, "Whose question?", agent, "tool", "ask_user"); code != 0 {
		t.Fatal(id)
	}
	if asks := openAsks(h, ""); len(asks) != 1 || asks[0].Session != "agent-session" {
		t.Fatalf("asks = %+v, want one from agent-session", asks)
	}
}
