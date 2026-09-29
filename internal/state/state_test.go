package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"kido/internal/testutil"
	"kido/internal/tmux"
)

func write(t *testing.T, id string, s Session) {
	t.Helper()
	s.PID = os.Getpid()
	b, err := json.Marshal(s)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(Dir(), id+".json"), b, 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestStalled pins the StallThreshold boundary; idle and waiting never
// count regardless of age.
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

// TestLoadAgentPrecedence pins that pi's record wins a shared pane over
// Claude Code's whatever the timestamps say.
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

func TestLoadSameAgentMostRecentWins(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("KIDO_STATE_DIR", dir)

	now := time.Now().UTC()
	write(t, "a", Session{Agent: AgentClaude, Pane: "%1", Status: Idle, TS: now.Add(-time.Minute)})
	write(t, "b", Session{Agent: AgentClaude, Pane: "%1", Status: Running, TS: now})

	states, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	got := states["%1"]
	if got.Status != Running {
		t.Errorf("status = %q, want the most recent record", got.Status)
	}
	if got.Agent != AgentClaude {
		t.Errorf("agent = %q, want %q", got.Agent, AgentClaude)
	}
}

// TestLoadTwoOuterRecordsOnOnePaneFlipByTimestamp pins that two pi
// records sharing one pane (a headless `pi --print` inheriting
// TMUX_PANE) fall through to beats' timestamp comparison and flip the
// winner - accepted, not fixed here, since reap is handed LoadLive
// rather than this collapsed view and so is unaffected by the flip.
func TestLoadTwoOuterRecordsOnOnePaneFlipByTimestamp(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("KIDO_STATE_DIR", dir)

	earlier := time.Now().UTC().Add(-time.Minute)
	later := time.Now().UTC()
	write(t, "pi-root", Session{Agent: AgentPi, Pane: "%9", Status: Idle, TS: earlier})
	write(t, "pi-headless", Session{Agent: AgentPi, Pane: "%9", Status: Running, TS: later})

	states, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if got := states["%9"]; got.ID != "pi-headless" {
		t.Errorf("pane %%9 = %+v, want the more recent record (pi-headless) to win the collision", got)
	}

	os.Remove(filepath.Join(dir, "pi-headless.json"))
	states, err = Load()
	if err != nil {
		t.Fatal(err)
	}
	if got := states["%9"]; got.ID != "pi-root" {
		t.Errorf("pane %%9 = %+v, want the surviving record (pi-root) once the collision ends", got)
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

// TestLoadDeletesDeadRecords pins the three cases the state directory can
// hold: a live file survives, a dead one is removed, a malformed one is
// skipped without stopping the walk.
func TestLoadDeletesDeadRecords(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("KIDO_STATE_DIR", dir)

	write(t, "live", Session{Pane: "%1", Status: Idle, TS: time.Now().UTC()})

	dead := testutil.DeadPID(t)
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
	for _, s := range []Status{"unknown", "", "busy"} {
		if Valid(s) {
			t.Errorf("%q should not be reportable", s)
		}
	}
}

// TestStalledIgnoresASessionParkedOnBackgroundWork pins that the
// exemption is on the Background flag, not the clock, so it holds
// however long the work takes.
func TestStalledIgnoresASessionParkedOnBackgroundWork(t *testing.T) {
	saved := StallThreshold
	StallThreshold = time.Minute
	t.Cleanup(func() { StallThreshold = saved })

	reported := time.Unix(1700000000, 0)
	quiet := Session{Status: Running, TS: reported, Background: true}
	busy := Session{Status: Running, TS: reported}

	for _, after := range []time.Duration{2 * time.Minute, 24 * time.Hour} {
		now := reported.Add(after)
		if StalledSince(quiet, time.Time{}, now) {
			t.Errorf("%v after its last report, a session parked on background work is stalled", after)
		}
		if !StalledSince(busy, time.Time{}, now) {
			t.Errorf("%v after its last report, an ordinary running session is not stalled", after)
		}
	}
}

// TestStalledResumesOnceBackgroundWorkIsDone pins that once the flag is
// gone from the next record, silence is judged on the usual clock again.
func TestStalledResumesOnceBackgroundWorkIsDone(t *testing.T) {
	saved := StallThreshold
	StallThreshold = time.Minute
	t.Cleanup(func() { StallThreshold = saved })

	reported := time.Unix(1700000000, 0)
	s := Session{Status: Running, TS: reported}
	if !StalledSince(s, time.Time{}, reported.Add(2*time.Minute)) {
		t.Error("a running session with no background flag is not stalled")
	}
}

// TestStalledIgnoresASessionInsideAToolCall pins that ToolPending exempts
// a session from staleness, since a tool call reports nothing until it
// returns and has no upper bound.
func TestStalledIgnoresASessionInsideAToolCall(t *testing.T) {
	saved := StallThreshold
	StallThreshold = time.Minute
	t.Cleanup(func() { StallThreshold = saved })

	reported := time.Unix(1700000000, 0)
	inTool := Session{Status: Running, TS: reported, ToolPending: true}
	between := Session{Status: Running, TS: reported}

	for _, after := range []time.Duration{2 * time.Minute, 3 * time.Hour} {
		now := reported.Add(after)
		if StalledSince(inTool, time.Time{}, now) {
			t.Errorf("%v into a tool call, the session is stalled", after)
		}
		if !StalledSince(between, time.Time{}, now) {
			t.Errorf("%v with no tool running, the session is not stalled", after)
		}
	}
}

// TestRecordRefusesASecondLiveHolder pins that a session id has one live
// holder, whoever got there first.
func TestRecordRefusesASecondLiveHolder(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	held := Session{Pane: "%1", PID: 1, Status: Running, Inbox: "/tmp/held.sock", TS: time.Now().UTC()}
	if err := Record("s", held); err != nil {
		t.Fatal(err)
	}
	err := Record("s", Session{Pane: "%2", PID: os.Getpid(), Status: Idle, TS: time.Now().UTC()})
	if err == nil {
		t.Errorf("Record by a second live process = nil, want a refusal")
	}
	got, ok, _ := Get("s")
	if !ok || got.Pane != "%1" || got.PID != 1 || got.Inbox != "/tmp/held.sock" {
		t.Errorf("record = %+v, want the first holder's untouched", got)
	}
}

func TestRemoveLeavesAnotherHoldersRecord(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := Record("s", Session{Pane: "%1", PID: 1, Status: Running, TS: time.Now().UTC()}); err != nil {
		t.Fatal(err)
	}
	if err := Remove("s", os.Getpid()); err == nil {
		t.Errorf("Remove by a process that does not hold the session = nil, want a refusal")
	}
	if _, ok, _ := Get("s"); !ok {
		t.Errorf("the holder's record was removed by another process")
	}
}

func TestRecordTakesOverADeadHolder(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := Record("s", Session{Pane: "%1", PID: testutil.DeadPID(t), Status: Idle, TS: time.Now().UTC()}); err != nil {
		t.Fatal(err)
	}
	if err := Record("s", Session{Pane: "%2", PID: os.Getpid(), Status: Running, TS: time.Now().UTC()}); err != nil {
		t.Errorf("Record over a dead holder = %v, want the takeover to succeed", err)
	}
	got, _, _ := Get("s")
	if got.Pane != "%2" || got.PID != os.Getpid() {
		t.Errorf("record = %+v, want the new process's", got)
	}
}

// TestRecordByTheHolderIsAnOrdinaryUpdate is the negative control for the
// two refusal tests: the holder's own repeated writes must still succeed.
func TestRecordByTheHolderIsAnOrdinaryUpdate(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := Record("s", Session{Pane: "%1", PID: os.Getpid(), Status: Idle, TS: time.Now().UTC()}); err != nil {
		t.Fatal(err)
	}
	if err := Record("s", Session{Pane: "%1", PID: os.Getpid(), Status: Running, TS: time.Now().UTC()}); err != nil {
		t.Errorf("the holder's own second report = %v, want it written", err)
	}
	if got, _, _ := Get("s"); got.Status != Running {
		t.Errorf("record = %+v, want the holder's update", got)
	}
	if err := Remove("s", os.Getpid()); err != nil {
		t.Errorf("Remove by the holder = %v, want it removed", err)
	}
	if _, ok, _ := Get("s"); ok {
		t.Errorf("the holder's own record survived its removal")
	}
}
