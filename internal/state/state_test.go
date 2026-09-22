package state

import (
	"encoding/json"
	"os"
	"os/exec"
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

// TestStallThresholdFromEnv pins KIDO_STALL_THRESHOLD_MS: the e2e suite
// drives kido as a built binary, so an override that only ever reassigns
// the package variable (as TestStalled does) is invisible to it.
func TestStallThresholdFromEnv(t *testing.T) {
	saved := os.Getenv("KIDO_STALL_THRESHOLD_MS")
	t.Cleanup(func() {
		if saved == "" {
			os.Unsetenv("KIDO_STALL_THRESHOLD_MS")
		} else {
			os.Setenv("KIDO_STALL_THRESHOLD_MS", saved)
		}
	})

	os.Unsetenv("KIDO_STALL_THRESHOLD_MS")
	if got := stallThresholdFromEnv(3 * time.Minute); got != 3*time.Minute {
		t.Errorf("unset: got %v, want the default", got)
	}

	os.Setenv("KIDO_STALL_THRESHOLD_MS", "250")
	if got := stallThresholdFromEnv(3 * time.Minute); got != 250*time.Millisecond {
		t.Errorf("set to 250: got %v, want 250ms", got)
	}

	os.Setenv("KIDO_STALL_THRESHOLD_MS", "not-a-number")
	if got := stallThresholdFromEnv(3 * time.Minute); got != 3*time.Minute {
		t.Errorf("garbage: got %v, want the default", got)
	}
}

// TestStalled checks the boundary state.Stalled draws: just under
// StallThreshold is not stalled, just over is, and neither idle nor
// waiting - however long they have gone quiet - ever count, since a
// wedged agent is defined as one that claims to be Running.
func TestStalled(t *testing.T) {
	saved := StallThreshold
	StallThreshold = time.Minute
	t.Cleanup(func() { StallThreshold = saved })

	now := time.Now()
	cases := []struct {
		name string
		s    Session
		want bool
	}{
		{"just under the threshold", Session{Status: Running, TS: now.Add(-59 * time.Second)}, false},
		{"exactly at the threshold", Session{Status: Running, TS: now.Add(-time.Minute)}, true},
		{"well over the threshold", Session{Status: Running, TS: now.Add(-5 * time.Minute)}, true},
		{"idle, however stale", Session{Status: Idle, TS: now.Add(-time.Hour)}, false},
		{"waiting, however stale", Session{Status: Waiting, TS: now.Add(-time.Hour)}, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := Stalled(c.s, now); got != c.want {
				t.Errorf("Stalled() = %v, want %v", got, c.want)
			}
		})
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

// deadPID starts and waits for a trivial child process, returning its pid:
// guaranteed to belong to no process by the time the caller uses it.
func deadPID(t *testing.T) int {
	t.Helper()
	cmd := exec.Command("true")
	if err := cmd.Run(); err != nil {
		t.Fatal(err)
	}
	return cmd.Process.Pid
}

// TestLoadDeletesDeadRecords checks the three cases the state directory can
// hold: a live session's file survives, a dead one's file is both skipped
// and removed from disk, and a malformed file is skipped without stopping
// the walk over the rest of the directory.
func TestLoadDeletesDeadRecords(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("KIDO_STATE_DIR", dir)

	write(t, "live", Session{Pane: "%1", Status: Idle, TS: time.Now().UTC()}) // write sets PID = os.Getpid()

	dead := deadPID(t)
	b, err := json.Marshal(Session{Pane: "%2", PID: dead, Status: Idle, TS: time.Now().UTC()})
	if err != nil {
		t.Fatal(err)
	}
	deadPath := filepath.Join(dir, "dead.json")
	if err := os.WriteFile(deadPath, b, 0o644); err != nil {
		t.Fatal(err)
	}

	malformedPath := filepath.Join(dir, "malformed.json")
	if err := os.WriteFile(malformedPath, []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}

	states, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := states["%1"]; !ok {
		t.Errorf("live record missing from Load's result: %+v", states)
	}
	if _, ok := states["%2"]; ok {
		t.Errorf("dead record should not be returned: %+v", states)
	}
	if _, err := os.Stat(deadPath); !os.IsNotExist(err) {
		t.Errorf("dead.json should have been deleted, stat err = %v", err)
	}
	if _, err := os.Stat(malformedPath); err != nil {
		t.Errorf("malformed.json should have been left alone: %v", err)
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
