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
	// pi titles its pane "π - <session> - <cwd>", and reports its status
	// with `kido agent-status` instead of a Claude Code hook.
	pane := h.piPane("alpha", "π - deploy - kido")

	for _, c := range []struct{ status, glyph string }{
		{"idle", ""},
		{"running", "◼"},
		{"waiting", "◆"},
		{"compacting", "◌"},
	} {
		h.agentStatus("pi-1", pane, "pi", c.status)
		h.waitGlyph("deploy - kido", c.glyph)
	}

	// Only pi's marker is stripped: the session and directory pi named
	// stay in the row, and the row is built exactly as a Claude pane's.
	claude := h.claudePane("alpha", "✳ deploy - kido")
	h.hook("sess-c", claude, "UserPromptSubmit")
	h.agentStatus("pi-1", pane, "pi", "running")
	h.waitGlyph("deploy - kido", "◼")
	h.waitFor(func() bool { return h.countRows("╶◼deploy - kido") == 2 }, settle,
		func() string {
			return fmt.Sprintf("two identical rows for the pi and claude panes (rows are %q)", h.rows())
		})

	// --remove drops pi's record at shutdown; the pane is then just a
	// process again, not an agent, and shows its foreground command. The
	// claude pane is the one that keeps the title row.
	h.agentStatus("pi-1", pane, "pi", "", "--remove")
	h.waitFor(func() bool {
		return h.countRows("╶◼deploy - kido") == 1 && h.countRows("╶ node") == 1
	}, settle, func() string {
		return fmt.Sprintf("the pi pane back to a plain node row (rows are %q)", h.rows())
	})
}

// A recorded --title must win over the session/cwd kido could otherwise
// derive by stripping pi's marker off the pane title, since splitting on
// "-" breaks for a session name that itself contains " - ".
func TestPiReportedTitleWinsOverPaneTitle(t *testing.T) {
	t.Parallel()
	h := start(t, "alpha")
	// The pane title alone would render as "deploy - kido" once the pi
	// marker is stripped; the reported title must win instead.
	pane := h.piPane("alpha", "π - deploy - kido")

	h.agentStatus("pi-3", pane, "pi", "idle", "--title", "deploy")
	h.waitGlyph("deploy", "")
	if got := h.rowFor("deploy"); got != "╶ deploy" {
		t.Fatalf("row = %q, want the reported title alone, not the pane title", got)
	}
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
	h.agentStatus("pi-2", pane, "pi", "running")
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
	h.agentStatus("pi-2", pane, "pi", "waiting")
	h.waitGlyph("bridge - kido", "◆")
	h.hook("inner-claude", pane, "UserPromptSubmit") // running
	time.Sleep(time.Second)
	if got := h.rowFor("bridge - kido"); got != "╶◆bridge - kido" {
		t.Fatalf("row = %q, want pi's waiting record to hold the pane", got)
	}

	// With pi gone, the inner record is all that is left and it shows.
	h.agentStatus("pi-2", pane, "pi", "", "--remove")
	h.waitGlyph("bridge - kido", "◼")
}

// A second live agent on the parent's pane wins it in the per-pane view;
// agent-alive reads every live record, so the parent still answers true.
func TestAgentAliveCmd(t *testing.T) {
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

	for i, c := range []struct{ session, want string }{
		{"parent", "true\nrc=0"},
		{"intruder", "true\nrc=0"},
		{"dead-sess", "false\nrc=0"},
		{"never-existed", "false\nrc=0"},
		{"''", "kido agent-alive: usage: kido agent-alive SESSION\nrc=1"},
	} {
		if got := strings.TrimSpace(h.runKido("alpha", fmt.Sprintf("alive-%d.out", i), "agent-alive", c.session)); got != c.want {
			t.Errorf("agent-alive %s = %q, want %q", c.session, got, c.want)
		}
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
	h.agentStatus("worker", pane, "pi", "running", "--title", "worker", "--inbox", "/tmp/nope.sock",
		"--parent-session", "p", "--depth", "1", "--model", "claude-sonnet-5", "--activity", "the old one")
	before := h.stateRecord("worker")
	setStatus := func(pane, activity string) (string, error) {
		cmd := exec.Command(kidoBin, "set_status", activity)
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

	want := `kido set_status: no agent session has reported pane "%999"; there is nothing to set an activity on`
	if out, err := setStatus("%999", "busy"); err == nil || out != want {
		t.Errorf("set_status from an unreported pane = %q (%v), want %q and a failure", out, err, want)
	}
}
