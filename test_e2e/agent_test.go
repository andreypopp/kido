package e2e

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func (h *harness) countRows(want string) int {
	h.t.Helper()
	n := 0
	for _, l := range h.rows() {
		if l == want {
			n++
		}
	}
	return n
}

func TestPiPaneIdentityRemovalPreservesNativeStatus(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	// pi titles its pane "π - <session> - <cwd>" and reports status with OSC 7501.
	pane := h.piPane("alpha", "π - deploy - kido")

	for _, c := range []struct{ state, glyph string }{
		{"idle", ""},
		{"working", "◼"},
		{"blocked", "◆"},
		{"working", "◼"},
	} {
		h.programStatus(pane, "state="+c.state+":app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", pane, "#{pane_title}"), "π - "))
		h.agentStatus("pi-1", pane)
		h.waitGlyph("deploy - kido", c.glyph)
	}

	// Removing identity does not clear the pane's terminal status.
	h.agentStatus("pi-1", pane, "--remove")
	h.waitFor(func() bool {
		return h.countRows("╶◼deploy - kido") == 0 && h.countRows("╶◼π - deploy - kido") == 1
	}, settle, func() string {
		return fmt.Sprintf("the bare pi pane retains its terminal status (rows are %q)", h.rows())
	})
}

func TestPiPaneTitleAndNativeStatus(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.piPane("alpha", "π - deploy - branch - kido")
	h.programStatus(pane, "state=working:app=pi:msg=ZGVwbG95IC0gYnJhbmNo")
	h.agentStatus("pi-3", pane)
	h.waitGlyph("deploy - branch - kido", "◼")
	if got := h.rowFor("deploy"); got != "╶◼deploy - branch - kido" {
		t.Fatalf("row = %q, want pane title, native status and no duplicate caption", got)
	}
	h.agentStatus("pi-3", pane, "--remove")
	h.waitGlyph("deploy - branch - kido", "◼")
	h.agentStatus("pi-3", pane)
	h.programStatus(pane, "state=clear")
	h.waitFor(func() bool { return !strings.Contains(h.rowFor("deploy"), "deploy - branch - kido") }, settle, msgf("clear hides the pi label despite its identity"))
}

// get-agent reads the run by id, so another agent claiming the parent's
// pane leaves the parent alive.
func TestGetAgentCmd(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.liveParent("alpha", "parent")
	h.liveParent("alpha", "intruder")
	dead := exec.Command("true")
	if err := dead.Run(); err != nil {
		t.Fatal(err)
	}
	rec, ok := h.readRecord(t, "parent")
	if !ok {
		t.Fatal("no run record for parent")
	}
	rec["pid"] = dead.Process.Pid
	b, _ := json.Marshal(rec)
	if err := os.MkdirAll(filepath.Join(h.stateDir, "runs", "dead-sess"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(h.stateDir, "runs", "dead-sess", "pi.json"), b, 0o644); err != nil {
		t.Fatal(err)
	}

	for i, c := range []struct {
		session string
		alive   bool
	}{
		{"parent", true},
		{"intruder", true},
		{"dead-sess", false},
		{"never-existed", false},
	} {
		args := []string{"get-agent", c.session}
		want := map[string]any{"id": c.session, "alive": c.alive}
		got := firstLine(h.runKido("alpha", fmt.Sprintf("alive-%d.out", i), args...))
		var value map[string]any
		if err := json.Unmarshal([]byte(got), &value); err != nil {
			t.Fatalf("get-agent: %s: %v", got, err)
		}
		b, _ := json.Marshal(want)
		actual, _ := json.Marshal(value)
		if string(actual) != string(b) {
			t.Errorf("get-agent %v = %s, want %s", args, actual, b)
		}
	}
	if got := strings.TrimSpace(h.runKido("alpha", "empty-session.out", "get-agent", "''")); got != "kido get-agent: usage: kido get-agent SESSION\nrc=1" {
		t.Errorf("empty session = %q", got)
	}
}

// The record is full of fields a rebuilt one would lose; only the
// activity may change.
func TestSetStatusCmd(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.in("display-message", "-p", "-t", "alpha:", "#{pane_id}")
	h.programStatus(pane, "state=working:app=pi", "worker")
	h.agentStatus("worker", pane, "--inbox", "/tmp/nope.sock", "--parent-session", "p", "--model", "claude-sonnet-5", "--activity", "the old one")
	before, ok := h.readRecord(t, "worker")
	if !ok {
		t.Fatal("no run record for worker")
	}
	setStatus := func(pane, activity string) (string, error) {
		cmd := exec.Command(kidoBin, "tool", "set_status", activity)
		cmd.Env = cleanEnv(append([]string{"TMUX_PANE=" + pane, "KIDO_STATE_DIR=" + h.stateDir}, h.caller(pane)...)...)
		out, err := cmd.CombinedOutput()
		return strings.TrimSpace(string(out)), err
	}

	for _, c := range []struct{ activity, want string }{
		{"refactoring internal/ui", "refactoring internal/ui"},
		{"two\nlines\tand more", "two lines and more"},
		{"", ""},
	} {
		if out, err := setStatus(pane, c.activity); err != nil {
			t.Fatalf("set_status %q: %v\n%s", c.activity, err, out)
		}
		after, ok := h.readRecord(t, "worker")
		if got, _ := after["activity"].(string); !ok || got != c.want {
			t.Errorf("set_status %q recorded %q, want %q", c.activity, got, c.want)
		}
		after["activity"] = before["activity"]
		if !reflect.DeepEqual(after, before) {
			t.Errorf("set_status %q changed more than the activity:\n got %v\nwant %v", c.activity, after, before)
		}
	}

	want := `kido tool set_status: no agent session is calling ($PI_SESSION_ID names none); there is nothing to set an activity on`
	if out, err := setStatus("%999", "busy"); err == nil || out != want {
		t.Errorf("set_status from no agent = %q (%v), want %q and a failure", out, err, want)
	}
}
