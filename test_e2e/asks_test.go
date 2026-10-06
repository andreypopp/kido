package e2e

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

type userAsk struct {
	ID          string `json:"id"`
	Session     string `json:"session"`
	SessionFile string `json:"sessionFile"`
	Cwd         string `json:"cwd"`
	Name        string `json:"name"`
	Text        string `json:"text"`
	Created     string `json:"created"`
	Ended       bool   `json:"ended"`
}

func askCommand(h *harness, pane, text string, args ...string) (string, int) {
	h.t.Helper()
	cmd := exec.Command(kidoBin, args...)
	cmd.Env = cleanEnv("TMUX="+h.inner+",0,0", "TMUX_PANE="+pane)
	cmd.Stdin = strings.NewReader(text)
	out, err := cmd.CombinedOutput()
	code := 0
	if exit, ok := err.(*exec.ExitError); ok {
		code = exit.ExitCode()
	} else if err != nil {
		h.t.Fatal(err)
	}
	return strings.TrimSpace(string(out)), code
}

func openAsks(h *harness, session string) []userAsk {
	h.t.Helper()
	args := []string{"get-asks"}
	if session != "" {
		args = append(args, "--session", session)
	}
	out, code := askCommand(h, "", "", args...)
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
	file := filepath.Join(h.dir, "session.jsonl")
	h.agentStatus("ask-session", pane, "pi", "idle", "--title", "Orchestrator")
	id, code := askCommand(h, pane, "Ship now?\nOr wait?", "tool", "ask_user", "--session-file", file)
	if code != 0 || !strings.HasPrefix(id, "A") || len(id) > 10 {
		t.Fatalf("ask_user: exit %d, %s", code, id)
	}
	asks := openAsks(h, "ask-session")
	if len(asks) != 1 || asks[0].ID != id || asks[0].Text != "Ship now?\nOr wait?" || asks[0].Name != "Orchestrator" || asks[0].Ended || asks[0].SessionFile != file {
		t.Fatalf("ask: %+v", asks)
	}
	first := asks[0]
	other, code := askCommand(h, pane, "Choose the colour?", "tool", "ask_user", "--session-file", file)
	if code != 0 || other == id || len(openAsks(h, "")) != 2 {
		t.Fatalf("second ask: exit %d, %s", code, other)
	}
	if got := openAsks(h, "no-session"); len(got) != 0 {
		t.Fatalf("session filter: %+v", got)
	}
	h.agentStatus("ask-session", pane, "pi", "idle", "--title", "Renamed")
	out, code := askCommand(h, pane, "Ship Monday?", "tool", "ask_user", "--replaces", id, "--session-file", file)
	asks = openAsks(h, "ask-session")
	if code != 0 || out != id || len(asks) != 2 || asks[1].ID != id || asks[1].Text != "Ship Monday?" || asks[1].Name != "Renamed" || asks[1].Created == first.Created {
		t.Fatalf("replacement: exit %d, %s, %+v", code, out, asks)
	}
	out, code = askCommand(h, pane, "Missing", "tool", "ask_user", "--replaces", "A1", "--session-file", file)
	if code != 1 || !strings.Contains(out, "no ask A1") {
		t.Fatalf("missing replace: exit %d, %s", code, out)
	}
	h.agentStatus("ask-session", pane, "pi", "", "--remove")
	asks = openAsks(h, "ask-session")
	if len(asks) != 2 || !asks[0].Ended || !asks[1].Ended {
		t.Fatalf("asks did not persist as ended: %+v", asks)
	}
	stored, err := os.ReadFile(filepath.Join(h.stateDir, "asks", id+".json"))
	if err != nil || strings.Contains(string(stored), "ended") {
		t.Fatalf("ended was persisted: %s, %v", stored, err)
	}
	h.agentStatus("ask-session", pane, "pi", "idle")
	if openAsks(h, "ask-session")[0].Ended {
		t.Fatal("resumed session still ended")
	}
	for _, ask := range []string{id, other} {
		out, code = askCommand(h, "", "", "tool", "remove_ask", ask)
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
	spawn, code := askCommand(h, pane, "", "tool", "spawn_subagent", "--parent-session", "ask-session", "--parent-pid", fmt.Sprint(os.Getpid()), "--name", "asking-child", "--task-file", task, "--", "sh", "-c", "exec sleep 300")
	fields := strings.Fields(spawn)
	if code != 0 || len(fields) != 3 {
		t.Fatalf("spawn child: exit %d, %s", code, spawn)
	}
	h.agentStatus(fields[2], fields[1], "pi", "idle", "--parent-session", "ask-session", "--parent-pid", fmt.Sprint(os.Getpid()), "--depth", "1")
	for _, args := range [][]string{{"tool", "ask_user", "--session-file", file}, {"tool", "remove_ask", id}} {
		out, code = askCommand(h, fields[1], "Question", args...)
		if code != 1 || !strings.Contains(out, "top-level agents only") {
			t.Fatalf("subagent refusal: exit %d, %s", code, out)
		}
	}
	h.agentStatus("nested-session", fields[1], "pi", "idle", "--parent-session", "ask-session", "--parent-pid", fmt.Sprint(os.Getpid()), "--depth", "1")
	nested, code := askCommand(h, fields[1], "Nested root question", "tool", "ask_user", "--session", "nested-session", "--session-file", file)
	if code != 0 {
		t.Fatalf("nested root was mistaken for its pane's run: exit %d, %s", code, nested)
	}
	out, code = askCommand(h, fields[1], "", "tool", "remove_ask", "--session", "nested-session", nested)
	if code != 0 {
		t.Fatalf("nested root remove: exit %d, %s", code, out)
	}
}
