package e2e

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func snapshotTitle(s feedSnapshot, pane string) string {
	for _, session := range s.Sessions {
		for _, row := range feedItems(session.Nodes) {
			if row.Pane != nil && *row.Pane == pane {
				return row.Title
			}
		}
	}
	return ""
}

// A run's row keeps the pi name its pane reports, before and after death.
func TestPiRenamedRunActuallyDies(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	root := h.firstPane("alpha")
	h.programStatus(root, "state=idle:app=pi")
	gate := filepath.Join(h.dir, "report-gate")
	script := fmt.Sprintf("while [ ! -f %s ]; do sleep 0.1; done; exec sleep 300", shellQuote(gate))
	pane := h.newWindow("alpha", "Launch", "sh", "-c", script)
	window := h.windowID(pane)
	h.in("set-window-option", "-t", window, "remain-on-exit", "on")
	h.in("set-option", "-p", "-t", pane, "@kido_run", "ending-child")
	h.agentRunMeta("ending-child", pane, "Launch", root)
	if err := os.WriteFile(gate, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	h.waitPaneCommand(pane, "sleep")
	h.programStatus(pane, "state=idle:app=pi")
	h.setPiOptions(pane, "ending-child", "Current", "", "")
	h.in("select-window", "-t", window)
	f := h.startFeed("alpha")
	f.waitLast(func(s feedSnapshot) bool { return snapshotTitle(s, pane) == "Current" }, "live renamed child")
	h.killPane(pane)
	f.waitLast(func(s feedSnapshot) bool {
		return snapshotTitle(s, pane) == "Current" && strings.Contains(strings.Join(s.drawn(), "\n"), "×Current")
	}, "dead child exact title")
	h.waitFor(func() bool { return h.rowFor("Current") == "└×Current failed" }, settle, msgf("dead child exact sidebar title"))
	h.in("select-window", "-t", h.windowID(root))
}

// A cleared pi name shows the pane's own title on the row, never a nested
// program's title.
func TestPiClearedNameUsesPaneTitleNotNestedTitle(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.piPane("alpha", "π - Pane fallback - kido")
	root := h.firstPane("alpha")
	h.programStatus(root, "state=idle:app=pi")
	h.agentRunMeta("clear-child", pane, "Launch", root)
	h.setPiOptions(pane, "clear-child", "Named", "", "")
	h.setPiOptions(pane, "clear-child", "", "", "")
	tty := h.in("display-message", "-p", "-t", pane, "#{pane_tty}")
	if err := os.WriteFile(tty, []byte("\x1b]7501;id=nested:state=blocked:app=builder:title=TmVzdGVk\x1b\\"), 0); err != nil {
		t.Fatal(err)
	}
	h.waitFor(func() bool {
		return strings.Contains(h.in("display-message", "-p", "-t", pane, "#{pane_program_status}"), `"id":"nested"`)
	}, settle, msgf("nested program status recorded"))
	f := h.startFeed("alpha")
	f.waitLast(func(s feedSnapshot) bool { return snapshotTitle(s, pane) == "π - Pane fallback - kido" }, "cleared pi exact pane title, not nested title")
	h.waitFor(func() bool { return strings.Contains(h.rowFor("Pane fallback"), "◆π - Pane fallback - kido") }, settle, msgf("cleared pi sidebar title (rows %v)", h.rows()))
	if out, rc := h.kidoAs(pane, "", nil, "run-outcome", "--result", "completed", "clear-child"); rc != 0 {
		t.Fatalf("ending: %d %s", rc, out)
	}
}
