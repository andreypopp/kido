package e2e

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSidebarAsksRevive(t *testing.T) {
	t.Parallel()
	fakeDir := t.TempDir()
	output := filepath.Join(fakeDir, "revived")
	fake := fmt.Sprintf("#!/bin/sh\nprintf '%%s\\n' \"$PWD\" \"$@\" > %s\nenv >> %s\nexec sleep 300\n", shellQuote(output), shellQuote(output))
	if err := os.WriteFile(filepath.Join(fakeDir, "pi"), []byte(fake), 0o755); err != nil {
		t.Fatal(err)
	}
	h := startPathPrefix(t, "alpha", fakeDir)
	cwd := filepath.Join(h.dir, "work dir")
	if err := os.Mkdir(cwd, 0o700); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(h.dir, "saved session.jsonl")
	if err := os.WriteFile(file, []byte("saved pi session"), 0o600); err != nil {
		t.Fatal(err)
	}
	pane := h.in("new-window", "-d", "-P", "-F", "#{pane_id}", "-t", "alpha:", "-c", cwd)
	h.agentStatus("ended-session", pane, "pi", "idle", "--title", "Ended")
	id, code := askCommand(h, pane, "Restart me?", "tool", "ask_user", "--session-file", file)
	if code != 0 {
		t.Fatal(id)
	}
	h.agentStatus("ended-session", pane, "pi", "", "--remove")
	focusSidebar(h)
	h.sendKeys("a")
	h.waitSelected("Ended " + id + " Restart me?")
	h.waitShellRow("Ended "+id+" Restart me?", "90")
	before := h.in("list-windows", "-a", "-F", "#{window_id}")
	if err := os.Remove(file); err != nil {
		t.Fatal(err)
	}
	h.sendKeys("Enter")
	h.waitRow("pi session file is gone")
	if got := h.in("list-windows", "-a", "-F", "#{window_id}"); got != before {
		t.Fatal("missing session file launched a window")
	}
	if err := os.WriteFile(file, []byte("saved pi session"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(cwd); err != nil {
		t.Fatal(err)
	}
	h.sendKeys("Enter")
	h.waitRow("ask directory is gone")
	if got := h.in("list-windows", "-a", "-F", "#{window_id}"); got != before {
		t.Fatal("missing cwd launched a window")
	}
	if err := os.Mkdir(cwd, 0o700); err != nil {
		t.Fatal(err)
	}
	h.in("set", "-g", "default-command", "/bin/false")
	h.sendKeys("Enter")
	got := h.waitFileNonEmpty(output)
	physical, err := filepath.EvalSymlinks(cwd)
	if err != nil {
		t.Fatal(err)
	}
	want := physical + "\n--session\n" + file + "\n"
	if !strings.HasPrefix(got, want) {
		t.Fatalf("revived pi got %q, want prefix %q", got, want)
	}
	for _, key := range []string{"KIDO_AGENT_PARENT_SESSION", "KIDO_AGENT_PARENT_PID", "KIDO_AGENT_RUN_ID", "KIDO_AGENT_TASK_FILE"} {
		if envLine(got, key) != "" {
			t.Fatalf("revived root inherited %s: %q", key, got)
		}
	}
	h.waitFocused(false)
	newPane := h.in("display-message", "-p", "-t", "alpha:", "#{pane_id}")
	mark := h.in("display-message", "-p", "-t", newPane, "#{@kido_run}")
	remain := h.in("show", "-Apv", "-t", newPane, "remain-on-exit")
	if newPane == pane || mark != "" || remain != "off" {
		t.Fatalf("revive did not make an ordinary new pane: %s, mark %q, remain-on-exit %q", newPane, mark, remain)
	}
	if len(openAsks(h, "ended-session")) != 1 {
		t.Fatal("revive removed the ask")
	}
	h.agentStatus("ended-session", newPane, "pi", "idle", "--title", "Revived")
	h.agentStatus("nested-competitor", newPane, "pi", "idle", "--title", "Other")
	focusSidebar(h)
	h.waitSelected(id)
	h.sendKeys("Enter")
	h.waitFocused(false)
	if h.in("display-message", "-p", "-t", "alpha:", "#{pane_id}") != newPane {
		t.Fatal("live session was not selected")
	}
	if got := h.in("list-windows", "-a", "-F", "#{window_id}"); len(strings.Fields(got)) != len(strings.Fields(before))+1 {
		t.Fatalf("live session revived again: %q", got)
	}
}
