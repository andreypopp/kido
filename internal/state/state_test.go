package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"kido/internal/tmux"
)

// write puts a state file in dir, as an agent would.
func write(t *testing.T, id string, s Session) {
	t.Helper()
	s.PID = os.Getpid() // alive, so Load keeps the record
	b, err := json.Marshal(s)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(Dir(), id+".json"), b, 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestLoadAgentPrecedence checks the rule that makes one pane resolve to
// one agent: pi runs Claude Code inside its own pane, so both write a
// record naming that pane and the pi one must win whatever the timestamps
// say.
func TestLoadAgentPrecedence(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("KIDO_STATE_DIR", dir)

	old := time.Now().UTC().Add(-time.Minute)
	write(t, "pi-1", Session{Agent: AgentPi, Pane: "%3", Status: Running, TS: old})
	write(t, "claude-1", Session{Agent: AgentClaude, Pane: "%3", Status: Idle, TS: time.Now().UTC()})

	states, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	got := states["%3"]
	if got.Agent != AgentPi || got.Status != Running {
		t.Errorf("pane %%3 = %+v, want the older pi record", got)
	}

	// The same holds when the claude record is the older one.
	write(t, "claude-1", Session{Agent: AgentClaude, Pane: "%3", Status: Idle, TS: old.Add(-time.Minute)})
	write(t, "pi-1", Session{Agent: AgentPi, Pane: "%3", Status: Waiting, TS: time.Now().UTC()})
	states, err = Load()
	if err != nil {
		t.Fatal(err)
	}
	if got := states["%3"]; got.Agent != AgentPi || got.Status != Waiting {
		t.Errorf("pane %%3 = %+v, want the pi record", got)
	}
}

// TestLoadSameAgentMostRecentWins checks that within one agent the latest
// record still wins, and that a file with no agent field (written before
// kido knew about other agents) reads as Claude Code.
func TestLoadSameAgentMostRecentWins(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("KIDO_STATE_DIR", dir)

	now := time.Now().UTC()
	write(t, "a", Session{Pane: "%1", Status: Idle, TS: now.Add(-time.Minute)})
	write(t, "b", Session{Pane: "%1", Status: Running, TS: now})

	states, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	got := states["%1"]
	if got.Status != Running {
		t.Errorf("status = %q, want the most recent record", got.Status)
	}
	if got.Agent != AgentClaude {
		t.Errorf("agent = %q, want %q for a file without one", got.Agent, AgentClaude)
	}
}

func TestIsAgentPane(t *testing.T) {
	states := map[string]Session{"%2": {Agent: AgentPi, Pane: "%2", Status: Running}}
	for _, c := range []struct {
		name string
		pi   map[int]bool
		pane tmux.Pane
		want bool
	}{
		{"reported", nil, tmux.Pane{PaneID: "%2", PanePID: 10, CurrentCommand: "node"}, true},
		{"claude command", nil, tmux.Pane{PaneID: "%9", PanePID: 11, CurrentCommand: "claude"}, true},
		{"pi in the tree", map[int]bool{12: true}, tmux.Pane{PaneID: "%9", PanePID: 12, CurrentCommand: "node"}, true},
		{"plain shell", map[int]bool{12: true}, tmux.Pane{PaneID: "%9", PanePID: 13, CurrentCommand: "bash"}, false},
	} {
		if got := IsAgentPane(states, c.pi, c.pane); got != c.want {
			t.Errorf("%s: IsAgentPane = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestValidStatus(t *testing.T) {
	for _, s := range Statuses() {
		if !Valid(s) {
			t.Errorf("%q should be reportable", s)
		}
	}
	for _, s := range []Status{Unknown, "", "busy"} {
		if Valid(s) {
			t.Errorf("%q should not be reportable", s)
		}
	}
}
