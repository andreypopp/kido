package e2e

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func snapshotTitle(s feedSnapshot, pane string) string {
	for _, session := range s.Sessions {
		for _, row := range feedItems(session.Nodes) {
			if row.Pane != nil && *row.Pane == pane {
				var title strings.Builder
				for _, span := range row.Title {
					title.WriteString(span.Text)
				}
				return title.String()
			}
		}
	}
	return ""
}

func TestPiRenamedRunActuallyDies(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	root := h.firstPane("alpha")
	in := startInbox(t, "ok\n")
	h.programStatus(root, "state=idle:app=pi")
	h.agentStatus("ending-root", root, "pi", "--name", "Root", "--inbox", in.Path)
	gate := filepath.Join(h.dir, "report-gate")
	ready := filepath.Join(h.dir, "reported-name")
	script := fmt.Sprintf("while [ ! -f %s ]; do sleep 0.1; done; %s agent-status --agent pi --session ending-child --name Current --parent-session ending-root; touch %s; exec sleep 300", shellQuote(gate), kidoBin, shellQuote(ready))
	pane := h.newWindow("alpha", "Launch", "sh", "-c", script)
	window := h.windowID(pane)
	h.in("set-window-option", "-t", window, "remain-on-exit", "on")
	h.in("set-option", "-p", "-t", pane, "@kido_run", "ending-child")
	h.agentRunMeta("ending-child", pane, "Launch", "ending-root")
	metaPath := filepath.Join(h.stateDir, "runs", "ending-child", "meta.json")
	metaBytes, err := os.ReadFile(metaPath)
	if err != nil {
		t.Fatal(err)
	}
	var meta map[string]any
	if err := json.Unmarshal(metaBytes, &meta); err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(h.in("display-message", "-p", "-t", pane, "#{pane_pid}"))
	if err != nil {
		t.Fatal(err)
	}
	meta["pid"] = pid
	metaBytes, err = json.Marshal(meta)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(metaPath, metaBytes, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(gate, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	h.waitFor(func() bool { _, err := os.Stat(ready); return err == nil }, settle, msgf("child's own name report"))
	h.waitPaneCommand(pane, "sleep")
	h.programStatus(pane, "state=idle:app=pi")
	h.in("select-window", "-t", window)
	f := h.startFeed("alpha")
	f.waitLast(func(s feedSnapshot) bool { return snapshotTitle(s, pane) == "Current" }, "live renamed child")
	h.killPane(pane)
	h.waitFor(func() bool {
		rows := h.listedRuns(root)
		return len(rows) == 1 && rows[0].State == "ended" && rows[0].Name == "Current"
	}, settle, msgf("dead run retains current name"))
	f.waitLast(func(s feedSnapshot) bool {
		return snapshotTitle(s, pane) == "Current" && strings.Contains(strings.Join(s.drawn(), "\n"), "×Current")
	}, "dead child exact title")
	h.waitFor(func() bool { return h.rowFor("Current") == "└×Current" }, settle, msgf("dead child exact sidebar title"))
	h.waitFor(func() bool {
		_, err := os.Stat(filepath.Join(h.stateDir, "ending-child.json"))
		return os.IsNotExist(err)
	}, settle, msgf("dead child State record removed"))
	h.in("select-window", "-t", h.windowID(root))
	h.waitFor(func() bool { return len(in.Received()) == 1 }, settle, msgf("death notice"))
	if got := envelopes(in)[0]; field(got, "from", "name") != "Current" || !strings.Contains(field(got, "text"), `subagent "Current"`) {
		t.Fatalf("death notice: %v", got)
	}
}

func TestPiClearedNameUsesPaneTitleForNestedProgramAndEnding(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	root := h.firstPane("alpha")
	in := startInbox(t, "ok\n")
	h.programStatus(root, "state=idle:app=pi")
	h.agentStatus("clear-root", root, "pi", "--name", "Root", "--inbox", in.Path)
	pane := h.piPane("alpha", "π - Pane fallback - kido")
	h.agentRunMeta("clear-child", pane, "Launch", "clear-root")
	h.agentStatus("clear-child", pane, "pi", "--name", "Named", "--parent-session", "clear-root")
	h.agentStatus("clear-child", pane, "pi", "--name", "", "--parent-session", "clear-root")
	h.programStatus(pane, "state=idle:app=pi")
	tty := h.in("display-message", "-p", "-t", pane, "#{pane_tty}")
	if err := os.WriteFile(tty, []byte("\x1b]7501;id=nested:state=blocked:app=builder:title=TmVzdGVk\x1b\\"), 0); err != nil {
		t.Fatal(err)
	}
	h.waitFor(func() bool {
		return strings.Contains(h.in("display-message", "-p", "-t", pane, "#{pane_program_status}"), `"id":"nested"`)
	}, settle, msgf("nested program status recorded"))
	f := h.startFeed("alpha")
	f.waitLast(func(s feedSnapshot) bool { return snapshotTitle(s, pane) == "π - Pane fallback - kido" }, "cleared pi exact pane title, not nested title")
	h.waitFor(func() bool { return h.rowFor("Pane fallback") == "└◆π - Pane fallback - kido" }, settle, msgf("cleared pi sidebar title (rows %v)", h.rows()))
	if out, rc := h.kidoAs(pane, "", nil, "run-outcome", "--result", "completed", "--unreported", "clear-child"); rc != 0 {
		t.Fatalf("ending: %d %s", rc, out)
	}
	if got := envelopes(in)[0]; field(got, "from", "name") != "π - Pane fallback - kido" || !strings.Contains(field(got, "text"), `subagent "π - Pane fallback - kido"`) {
		t.Fatalf("cleared-name ending notice: %v", got)
	}
}
