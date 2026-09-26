package e2e

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// readRecord is the state file for sessionID as it is on disk, and
// whether there is one. The claim is a rule about that file, so the test
// reads the file rather than anything kido says about it.
func (h *harness) readRecord(t *testing.T, sessionID string) (map[string]any, bool) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(h.stateDir, sessionID+".json"))
	if os.IsNotExist(err) {
		return nil, false
	}
	if err != nil {
		t.Fatal(err)
	}
	var rec map[string]any
	if err := json.Unmarshal(b, &rec); err != nil {
		t.Fatalf("state file for %s: %v", sessionID, err)
	}
	return rec, true
}

// TestSecondHolderOfASessionIdIsRefused is the incident end to end: two
// pi processes opened one session id (a test pi resuming a copy of
// another session's file), and the newcomer's report overwrote the
// record of the session that was actually running - wrong pane, wrong
// inbox - then deleted it on the way out.
//
// Both halves go through the real binary, from two panes, so the two
// reports come from two live pids; the record itself is read off disk.
// The takeover at the end is the control the refusal is unsafe without:
// a session id whose holder has died is free, which is what makes a
// restart possible at all.
func TestSecondHolderOfASessionIdIsRefused(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")

	// The holder: it reports and then stays alive, so the pid on its
	// record is a running process for as long as the pane is.
	script := fmt.Sprintf("%s agent-status --agent pi --session dup-e2e --status idle --title holder; exec sleep 300", kidoBin)
	holderPane := h.newWindow("alpha", "holder-e2e", "sh", "-c", script)
	h.waitPaneCommand(holderPane, "sleep")
	h.waitFor(func() bool { _, ok := h.readRecord(t, "dup-e2e"); return ok }, settle,
		msgf("the holder's own record to appear"))

	out := h.runKido("alpha", "intruder.out",
		"agent-status", "--agent", "pi", "--session", "dup-e2e", "--status", "running", "--title", "intruder")
	if !strings.Contains(out, "rc=6") {
		t.Errorf("a second live process reporting under a held session id = %q, want rc=6", out)
	}
	if !strings.Contains(out, "already open") {
		t.Errorf("output = %q, want it to say where the holder is", out)
	}
	rec, ok := h.readRecord(t, "dup-e2e")
	if !ok || rec["title"] != "holder" {
		t.Fatalf("record = %+v, want the holder's untouched", rec)
	}

	// The other half of the incident: the intruder exiting took the live
	// session's record with it.
	out = h.runKido("alpha", "remove.out",
		"agent-status", "--agent", "pi", "--session", "dup-e2e", "--remove")
	if !strings.Contains(out, "rc=6") {
		t.Errorf("a second live process removing a held session's record = %q, want rc=6", out)
	}
	if rec, ok := h.readRecord(t, "dup-e2e"); !ok || rec["title"] != "holder" {
		t.Errorf("record = %+v (present %v), want the holder's still there", rec, ok)
	}

	// The takeover: with the holder gone, its session id is free. The
	// restarted process reports from a pane of its own and stays there,
	// as the holder did - a reporter that exits leaves a dead-pid record,
	// which the sidebar's own poll deletes within a tick.
	h.killPane(holderPane)
	restart := fmt.Sprintf("%s agent-status --agent pi --session dup-e2e --status idle --title restarted; exec sleep 300", kidoBin)
	restartPane := h.newWindow("alpha", "restarted-e2e", "sh", "-c", restart)
	h.waitPaneCommand(restartPane, "sleep")
	h.waitFor(func() bool {
		rec, ok := h.readRecord(t, "dup-e2e")
		return ok && rec["title"] == "restarted"
	}, settle, func() string {
		rec, ok := h.readRecord(t, "dup-e2e")
		return fmt.Sprintf("the record to be the restarted process's; it is %+v (present %v)", rec, ok)
	})
}
