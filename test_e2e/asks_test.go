package e2e

import (
	"encoding/json"
	"fmt"
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

func setOneAsk(h *harness, pane, text string) (string, int) {
	h.t.Helper()
	input, err := json.Marshal([]map[string]string{{"text": text}})
	if err != nil {
		h.t.Fatal(err)
	}
	out, code := h.kidoAs(pane, string(input), nil, "tool", "set_asks")
	if code != 0 {
		return out, code
	}
	var asks []userAsk
	if err := json.Unmarshal([]byte(out), &asks); err != nil || len(asks) != 1 {
		h.t.Fatalf("set_asks: %s, %v", out, err)
	}
	return asks[0].ID, code
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

func TestAskSetSessionScope(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.in("display-message", "-p", "-t", "alpha:", "#{pane_id}")
	other := h.newWindow("alpha", "other", "sh", "-c", "exec sleep 300")
	h.programStatus(pane, "state=idle:app=pi", "First")
	h.agentStatus("first-session", pane)
	h.programStatus(other, "state=idle:app=pi", "Other")
	h.agentStatus("other-session", other)
	id, code := setOneAsk(h, other, "Other decision?")
	if code != 0 {
		t.Fatal(id)
	}
	own, code := setOneAsk(h, pane, "Own decision?")
	if code != 0 {
		t.Fatal(own)
	}
	out, code := h.kidoAs(pane, fmt.Sprintf(`[{"text":"Must not create"},{"id":%q,"text":"Must not take"}]`, id), nil, "tool", "set_asks")
	if code != 1 || !strings.Contains(out, "no ask "+id) {
		t.Fatalf("foreign id: exit %d, %s", code, out)
	}
	asks := openAsks(h, "first-session")
	if len(asks) != 1 || asks[0].ID != own || asks[0].Text != "Own decision?" {
		t.Fatalf("refused list changed session: %+v", asks)
	}
	out, code = h.kidoAs(pane, "[]", nil, "tool", "set_asks")
	asks = openAsks(h, "")
	if code != 0 || out != "[]" || len(asks) != 1 || asks[0].ID != id || asks[0].Text != "Other decision?" {
		t.Fatalf("clear crossed sessions: exit %d, %s, %+v", code, out, asks)
	}
}

func TestAskSetLifecycle(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.in("display-message", "-p", "-t", "alpha:", "#{pane_id}")
	h.programStatus(pane, "state=idle:app=pi", "Orchestrator")
	h.agentStatus("ask-session", pane)
	out, code := h.kidoAs(pane, `[{"text":"Ship now?\nOr wait?"},{"text":"Choose the colour?"}]`, nil, "tool", "set_asks")
	var result []userAsk
	if code != 0 || json.Unmarshal([]byte(out), &result) != nil || len(result) != 2 {
		t.Fatalf("set_asks: exit %d, %s", code, out)
	}
	id, other := result[0].ID, result[1].ID
	asks := openAsks(h, "ask-session")
	if len(asks) != 2 || id == other || !strings.HasPrefix(id, "A") {
		t.Fatalf("asks: %+v", asks)
	}
	var first userAsk
	for _, a := range asks {
		if a.ID == id {
			first = a
		}
	}
	if first.Text != "Ship now?\nOr wait?" || first.Name != "Orchestrator" || first.Ended {
		t.Fatalf("ask: %+v", first)
	}
	if got := openAsks(h, "no-session"); len(got) != 0 {
		t.Fatalf("session filter: %+v", got)
	}
	h.programStatus(pane, "state=idle:app=pi", "Renamed")
	h.agentStatus("ask-session", pane)
	out, code = h.kidoAs(pane, fmt.Sprintf(`[{"id":%q,"text":"Ship Monday?"},{"text":"Which version?"}]`, id), nil, "tool", "set_asks")
	if code != 0 || json.Unmarshal([]byte(out), &result) != nil || len(result) != 2 || result[0].ID != id || result[1].ID == other {
		t.Fatalf("replacement order: exit %d, %s", code, out)
	}
	asks = openAsks(h, "ask-session")
	var changed userAsk
	for _, a := range asks {
		if a.ID == id {
			changed = a
		}
		if a.ID == other {
			t.Fatal("omitted ask remains")
		}
	}
	if len(asks) != 2 || changed.Text != "Ship Monday?" || changed.Name != "Renamed" || changed.Created == first.Created {
		t.Fatalf("replacement: %+v", asks)
	}
	input, err := json.Marshal([]map[string]string{{"id": id, "text": changed.Text}, {"id": result[1].ID, "text": result[1].Text}})
	if err != nil {
		t.Fatal(err)
	}
	stored, err := os.ReadFile(filepath.Join(h.stateDir, "asks", id+".json"))
	if err != nil {
		t.Fatal(err)
	}
	out, code = h.kidoAs(pane, string(input), nil, "tool", "set_asks")
	unchanged, err := os.ReadFile(filepath.Join(h.stateDir, "asks", id+".json"))
	if code != 0 || err != nil || string(stored) != string(unchanged) {
		t.Fatalf("unchanged file: exit %d, %s, %v", code, out, err)
	}
	before, err := json.Marshal(openAsks(h, ""))
	if err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{
		fmt.Sprintf(`[{"id":%q,"text":"Must not change"},{"id":"A1","text":"Missing"}]`, id),
		fmt.Sprintf(`[{"id":%q,"text":"Must not change"},{"id":%q,"text":"Duplicate"}]`, id, id),
		fmt.Sprintf(`[{"id":%q,"text":"Must not change"},{"text":"  "}]`, id),
		fmt.Sprintf(`[{"id":%q,"text":"Must not change"},{"text":"%s"}]`, id, string([]byte{0xff})),
		`[{"text":"Must not create"},{"id":"invalid","text":"Bad id"}]`,
		`[{"text":"Must not create"},{"id":"A1","text":"Missing"}]`,
	} {
		out, code = h.kidoAs(pane, bad, nil, "tool", "set_asks")
		if code != 1 {
			t.Fatalf("invalid list accepted: %s", out)
		}
		unchanged, err = os.ReadFile(filepath.Join(h.stateDir, "asks", id+".json"))
		after, marshalErr := json.Marshal(openAsks(h, ""))
		if err != nil || marshalErr != nil || string(stored) != string(unchanged) || string(before) != string(after) {
			t.Fatalf("invalid list changed asks: %s, %v", out, err)
		}
	}
	h.agentStatus("ask-session", pane, "--remove")
	asks = openAsks(h, "ask-session")
	if len(asks) != 2 || !asks[0].Ended || !asks[1].Ended {
		t.Fatalf("asks did not persist as ended: %+v", asks)
	}
	if strings.Contains(string(stored), "ended") {
		t.Fatalf("ended was persisted: %s", stored)
	}
	h.agentStatus("ask-session", pane)
	if openAsks(h, "ask-session")[0].Ended {
		t.Fatal("resumed session still ended")
	}
	out, code = h.kidoAs(pane, "[]", nil, "tool", "set_asks")
	if code != 0 || out != "[]" || len(openAsks(h, "")) != 0 {
		t.Fatalf("clear: exit %d, %s", code, out)
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
	for _, args := range [][]string{{"tool", "set_asks"}, {"remove-ask", id}} {
		out, code = h.kidoAs(fields[1], "Question", nil, args...)
		if code != 1 || !strings.Contains(out, "top-level agents only") {
			t.Fatalf("subagent refusal: exit %d, %s", code, out)
		}
	}
	h.programStatus(fields[1], "state=idle:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", fields[1], "#{pane_title}"), "π - "))
	h.agentStatus("nested-session", fields[1])
	nested, code := setOneAsk(h, fields[1], "Nested root question")
	if code != 0 {
		t.Fatalf("nested root was mistaken for its pane's run: exit %d, %s", code, nested)
	}
	out, code = h.kidoAs(fields[1], "", nil, "remove-ask", nested)
	if code != 0 {
		t.Fatalf("nested root remove: exit %d, %s", code, out)
	}
}

// A headless pi in an agent's pane reports after the agent, so it is the
// pane's latest record; the agent's own set_asks still names the agent,
// since the caller is the session pi names, not whoever reported the pane.
func TestAskNamesTheCallingSessionNotThePane(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.in("display-message", "-p", "-t", "alpha:", "#{pane_id}")
	h.programStatus(pane, "state=idle:app=pi", "Agent")
	h.agentStatus("agent-session", pane)
	agent := h.caller(pane)
	h.agentStatus("headless-session", pane)
	if id, code := h.kidoAs(pane, `[{"text":"Whose question?"}]`, agent, "tool", "set_asks"); code != 0 {
		t.Fatal(id)
	}
	if asks := openAsks(h, ""); len(asks) != 1 || asks[0].Session != "agent-session" {
		t.Fatalf("asks = %+v, want one from agent-session", asks)
	}
}
