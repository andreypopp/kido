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

// TestLoadTwoOuterRecordsOnOnePaneFlipByTimestamp pins the case AGENTS.md
// flags as unenforced and untested: outer() treats any two non-Claude
// agents as equally "outer", so two pi records sharing one pane (the real
// incident this guards - a headless `pi --print` inheriting TMUX_PANE
// from the pane it was launched in) fall through to beats' timestamp
// comparison and the winner flips to whichever reported most recently.
// This is deliberately NOT "fixed" into a stable tiebreak here: the same
// timestamp-wins rule is what TestLoadSameAgentMostRecentWins pins for the
// ordinary case of one real agent's own record evolving over the pane's
// lifetime (a new Claude Code session id replacing an old one after
// /clear, say), and a tiebreak that instead favoured the older record
// would silently break that - it has no way to tell "a legitimate second
// record for this pane" from "an intruder that inherited a pane it never
// owned". The fix for the destructive consequence of this flip is not to
// stop the flip but to stop asking a question it can answer wrongly:
// internal/reap is handed LoadLive, every live record rather than one per
// pane, and a collision cannot hide a parent from a set that was never
// collapsed. This test just records that the flip itself is real and
// known, not a surprise.
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

	// The headless record ends (its file is removed, as session_shutdown
	// does on exit) and the root's own record is the only one left.
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

// A session Stop parked on background work claims running and then goes
// quiet by design: Claude Code emits nothing while a background shell
// runs, so its record cannot be refreshed and would cross the threshold
// three minutes after every backgrounded turn. The exemption is on the
// flag, not on the clock, so it holds however long the work takes.
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

// The exemption must not swallow the case it looks like: once the work
// ends, the flag is gone from the next record, and an agent that then
// falls silent is stalled on the usual clock.
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

// A tool call reports nothing until it returns and has no upper bound, so
// a session in one is working, not wedged. This is the case that lit up a
// real sidebar: a Bash call to a slow host, seven minutes with no event.
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

// TestRecordRefusesASecondLiveHolder is the second incident: two
// processes opened one session id - a test pi resuming a copy of another
// session's file - and the newcomer's report overwrote the record of the
// session that was actually running, giving it a wrong pane and a wrong
// inbox. A session id has one live holder, and it is whoever got there
// first.
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

// TestRemoveLeavesAnotherHoldersRecord is the same incident's second
// half: the intruder exited and took the live session's record with it.
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

// TestRecordTakesOverADeadHolder is the restart case, at the record
// level: the previous process is gone, so its session id is free.
func TestRecordTakesOverADeadHolder(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := Record("s", Session{Pane: "%1", PID: deadPID(t), Status: Idle, TS: time.Now().UTC()}); err != nil {
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

// TestRecordByTheHolderIsAnOrdinaryUpdate is the control the two
// refusals above are unsafe without: every report after the first is a
// second write of a session id that already has a live record on disk,
// and a claim that read only "a live record exists" would refuse them
// all and leave every agent frozen at its first status.
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
