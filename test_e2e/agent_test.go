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
	"time"
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

// TestPiPaneLooksLikeAClaudePane checks that an agent that is not Claude
// Code gets exactly the row a Claude Code pane gets: a status indicator and
// the title, with nothing on screen saying which agent it is.
func TestPiPaneLooksLikeAClaudePane(t *testing.T) {
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
		h.agentStatus("pi-1", pane, "pi")
		h.waitGlyph("deploy - kido", c.glyph)
	}

	// Only pi's marker is stripped: the session and directory pi named
	// stay in the row, and the row is built exactly as a Claude pane's.
	claude := h.claudePane("alpha", "✳ deploy - kido")
	h.hook("sess-c", claude, "UserPromptSubmit")
	h.programStatus(pane, "state=working:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", pane, "#{pane_title}"), "π - "))
	h.agentStatus("pi-1", pane, "pi")
	h.waitGlyph("deploy - kido", "◼")
	h.waitFor(func() bool { return h.countRows("╶◼deploy - kido") == 2 }, settle,
		func() string {
			return fmt.Sprintf("two identical rows for the pi and claude panes (rows are %q)", h.rows())
		})

	// Removing identity does not clear the pane's terminal status.
	h.agentStatus("pi-1", pane, "pi", "--remove")
	h.waitFor(func() bool {
		return h.countRows("╶◼deploy - kido") == 2
	}, settle, func() string {
		return fmt.Sprintf("the bare pi pane retains its terminal status (rows are %q)", h.rows())
	})
}

func TestPiPaneTitleAndNativeStatus(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.piPane("alpha", "π - deploy - branch - kido")
	h.programStatus(pane, "state=working:app=pi:msg=ZGVwbG95IC0gYnJhbmNo")
	h.agentStatus("pi-3", pane, "pi")
	h.waitGlyph("deploy - branch - kido", "◼")
	if got := h.rowFor("deploy"); got != "╶◼deploy - branch - kido" {
		t.Fatalf("row = %q, want pane title, native status and no duplicate caption", got)
	}
	h.agentStatus("pi-3", pane, "pi", "--remove")
	h.waitGlyph("deploy - branch - kido", "◼")
	h.agentStatus("pi-3", pane, "pi")
	h.programStatus(pane, "state=clear")
	h.waitGlyph("deploy - branch - kido", "?")
}

// TestPiBeatsClaudeOnTheSamePane checks the precedence rule. pi runs Claude
// Code inside its own pane (pi-claude-bridge, headless), and that Claude
// Code's hooks fire with pi's TMUX_PANE, so both agents write a record for
// the one pane. The pane is pi's, whichever wrote last.
func TestPiBeatsClaudeOnTheSamePane(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.piPane("alpha", "π - bridge - kido")

	// pi first, so its record is the older one: a most-recent-wins rule
	// would show the inner Claude Code's idle instead.
	h.programStatus(pane, "state=working:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", pane, "#{pane_title}"), "π - "))
	h.agentStatus("pi-2", pane, "pi")
	h.waitGlyph("bridge - kido", "◼")
	h.hook("inner-claude", pane, "SessionStart") // idle
	// Long enough for ten ticks: the pi record must keep the pane, not
	// just win the race to be read first.
	time.Sleep(time.Second)
	if got := h.rowFor("bridge - kido"); got != "╶◼bridge - kido" {
		t.Fatalf("row = %q, want pi's running record to hold the pane", got)
	}

	// And the other way round: pi's record is now the newer one, and the
	// inner Claude Code reporting again must not take the pane back.
	h.programStatus(pane, "state=blocked:app=pi", strings.TrimPrefix(h.in("display-message", "-p", "-t", pane, "#{pane_title}"), "π - "))
	h.agentStatus("pi-2", pane, "pi")
	h.waitGlyph("bridge - kido", "◆")
	h.hook("inner-claude", pane, "UserPromptSubmit") // running
	time.Sleep(time.Second)
	if got := h.rowFor("bridge - kido"); got != "╶◆bridge - kido" {
		t.Fatalf("row = %q, want pi's waiting record to hold the pane", got)
	}

	// With pi gone, the inner record is all that is left and it shows.
	h.agentStatus("pi-2", pane, "pi", "--remove")
	h.waitGlyph("bridge - kido", "◼")
}

// A second live agent on the parent's pane wins it in the per-pane view;
// get-agent reads every live record, so the parent still answers true.
func TestGetAgentCmd(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	h.liveParent("alpha", "parent")
	h.liveParent("alpha", "intruder")
	dead := exec.Command("true")
	if err := dead.Run(); err != nil {
		t.Fatal(err)
	}
	rec := h.stateRecord("parent")
	rec["pid"] = dead.Process.Pid
	b, _ := json.Marshal(rec)
	if err := os.WriteFile(filepath.Join(h.stateDir, "dead-sess.json"), b, 0o644); err != nil {
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
		for _, children := range []bool{false, true} {
			args := []string{"get-agent", c.session}
			want := map[string]any{"id": c.session, "alive": c.alive}
			if children {
				args = append(args, "--children")
				want["childrenAlive"] = false
				want["keepAlive"] = false
			}
			got := firstLine(h.runKido("alpha", fmt.Sprintf("alive-%d-%t.out", i, children), args...))
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
	}
	if _, err := os.Stat(filepath.Join(h.stateDir, "dead-sess.json")); !os.IsNotExist(err) {
		t.Errorf("dead record was not removed: %v", err)
	}
	if got := strings.TrimSpace(h.runKido("alpha", "empty-session.out", "get-agent", "''")); got != "kido get-agent: usage: kido get-agent SESSION\nrc=1" {
		t.Errorf("empty session = %q", got)
	}
}

func (h *harness) stateRecord(sessionID string) map[string]any {
	h.t.Helper()
	b, err := os.ReadFile(filepath.Join(h.stateDir, sessionID+".json"))
	if err != nil {
		h.t.Fatal(err)
	}
	var rec map[string]any
	if err := json.Unmarshal(b, &rec); err != nil {
		h.t.Fatal(err)
	}
	return rec
}

// The record is full of fields a rebuilt one would lose; only the
// activity may change.
func TestSetStatusCmd(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	pane := h.in("display-message", "-p", "-t", "alpha:", "#{pane_id}")
	h.programStatus(pane, "state=working:app=pi", "worker")
	h.agentStatus("worker", pane, "pi", "--inbox", "/tmp/nope.sock", "--parent-session", "p", "--depth", "1", "--model", "claude-sonnet-5", "--activity", "the old one")
	before := h.stateRecord("worker")
	setStatus := func(pane, activity string) (string, error) {
		cmd := exec.Command(kidoBin, "tool", "set_status", activity)
		cmd.Env = cleanEnv("TMUX_PANE="+pane, "KIDO_STATE_DIR="+h.stateDir)
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
		after := h.stateRecord("worker")
		if got, _ := after["activity"].(string); got != c.want {
			t.Errorf("set_status %q recorded %q, want %q", c.activity, got, c.want)
		}
		after["activity"] = before["activity"]
		if !reflect.DeepEqual(after, before) {
			t.Errorf("set_status %q changed more than the activity:\n got %v\nwant %v", c.activity, after, before)
		}
	}

	want := `kido tool set_status: no agent session has reported pane "%999"; there is nothing to set an activity on`
	if out, err := setStatus("%999", "busy"); err == nil || out != want {
		t.Errorf("set_status from an unreported pane = %q (%v), want %q and a failure", out, err, want)
	}
}
