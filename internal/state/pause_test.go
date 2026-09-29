package state

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"testing"
	"time"
)

// TestPauseGap pins DetectPause's arithmetic at the PauseSlack boundary,
// with synthetic durations rather than sleeping the machine.
func TestPauseGap(t *testing.T) {
	saved := PauseSlack
	PauseSlack = time.Second
	t.Cleanup(func() { PauseSlack = saved })

	cases := []struct {
		name       string
		wall, mono time.Duration
		want       bool
	}{
		{"awake, tick on schedule", 100 * time.Millisecond, 100 * time.Millisecond, false},
		{"awake, tick genuinely slow", 5 * time.Minute, 5 * time.Minute, false},
		{"just under the slack", 999 * time.Millisecond, 0, false},
		{"just over the slack", time.Second + time.Millisecond, 0, true},
		{"asleep for minutes", 5 * time.Minute, 50 * time.Millisecond, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := pauseGap(c.wall, c.mono); got != c.want {
				t.Errorf("pauseGap(%v, %v) = %v, want %v", c.wall, c.mono, got, c.want)
			}
		})
	}
}

// TestDetectPauseDegradesWithoutMonotonic pins that DetectPause never
// fires for two Time values with no monotonic reading (e.g. time.Unix,
// every test clock in this repo).
func TestDetectPauseDegradesWithoutMonotonic(t *testing.T) {
	prev := time.Unix(1700000000, 0)
	now := prev.Add(10 * time.Minute)
	if DetectPause(prev, now) {
		t.Error("DetectPause fired on Time values with no monotonic reading")
	}
}

// TestStalledRebasesAfterPause pins that once a pause is recorded, a
// session whose TS predates the wake is judged from the wake, not TS.
func TestStalledRebasesAfterPause(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())

	saved := StallThreshold
	StallThreshold = time.Minute
	t.Cleanup(func() { StallThreshold = saved })

	reported := time.Unix(1700000000, 0)
	wake := reported.Add(time.Hour)
	if err := RecordPause(wake); err != nil {
		t.Fatal(err)
	}

	s := Session{Status: Running, TS: reported}

	if Stalled(s, wake) {
		t.Error("stalled the instant the machine woke, with no chance to heartbeat yet")
	}
	if Stalled(s, wake.Add(StallThreshold-time.Second)) {
		t.Error("stalled just under a threshold after the wake")
	}
	if !Stalled(s, wake.Add(StallThreshold)) {
		t.Error("not stalled a full threshold after the wake, though it never reported again")
	}

	s.TS = wake.Add(time.Second)
	if Stalled(s, wake.Add(StallThreshold)) {
		t.Error("a session that reported after the wake was judged against the wake instead of its own TS")
	}
}

// TestStalledSinceTakesTheBaselineItIsGiven pins that StalledSince judges
// against the wake it is handed and reads nothing; Stalled is the form
// that reads the marker.
func TestStalledSinceTakesTheBaselineItIsGiven(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())

	saved := StallThreshold
	StallThreshold = time.Minute
	t.Cleanup(func() { StallThreshold = saved })

	reported := time.Unix(1700000000, 0)
	wake := reported.Add(time.Hour)
	if err := RecordPause(wake); err != nil {
		t.Fatal(err)
	}
	s := Session{Status: Running, TS: reported}
	now := wake.Add(time.Second)

	if !StalledSince(s, time.Time{}, now) {
		t.Error("StalledSince rebased onto the recorded wake, though it was handed no baseline")
	}
	if !StalledSince(s, reported, now) {
		t.Error("StalledSince rebased onto the recorded wake, though it was handed an older one")
	}
	if Stalled(s, now) {
		t.Error("Stalled ignored the recorded wake: it is the form that reads the marker")
	}
	if got := Wake(); !got.Equal(wake) {
		t.Errorf("Wake() = %v, want the recorded %v", got, wake)
	}
}

// TestRecordPauseKeepsTheLatest pins that an older wake never clobbers a
// newer one already recorded.
func TestRecordPauseKeepsTheLatest(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())

	later := time.Unix(1700001000, 0)
	earlier := time.Unix(1700000000, 0)
	if err := RecordPause(later); err != nil {
		t.Fatal(err)
	}
	if err := RecordPause(earlier); err != nil {
		t.Fatal(err)
	}
	got := Wake()
	if got.IsZero() {
		t.Fatalf("Wake: %v", got)
	}
	if !got.Equal(later) {
		t.Errorf("wake marker = %v, want the later write %v to survive", got, later)
	}
}

// TestStalledCrossProcess pins that the rebased verdict is readable from
// disk by a second process that never itself detected the pause (e.g.
// `kido list_agents` shelled out to fresh), not just held in memory.
func TestStalledCrossProcess(t *testing.T) {
	if os.Getenv("KIDO_PAUSE_HELPER") == "1" {
		runStalledHelper(t)
		return
	}

	dir := t.TempDir()
	t.Setenv("KIDO_STATE_DIR", dir)

	saved := StallThreshold
	StallThreshold = time.Minute
	t.Cleanup(func() { StallThreshold = saved })

	reported := time.Unix(1700000000, 0)
	wake := reported.Add(time.Hour)
	if err := RecordPause(wake); err != nil {
		t.Fatal(err)
	}

	run := func(now time.Time) string {
		t.Helper()
		cmd := exec.Command(os.Args[0], "-test.run=TestStalledCrossProcess")
		cmd.Env = append(os.Environ(),
			"KIDO_PAUSE_HELPER=1",
			"KIDO_STATE_DIR="+dir,
			fmt.Sprintf("KIDO_STALL_THRESHOLD_MS=%d", StallThreshold.Milliseconds()),
			"HELPER_TS="+reported.Format(time.RFC3339Nano),
			"HELPER_NOW="+now.Format(time.RFC3339Nano),
		)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("helper process: %v\n%s", err, out)
		}
		return string(out)
	}

	if got := run(wake); got != "false\nPASS\n" {
		t.Errorf("second process, right at wake: got %q, want \"false\"", got)
	}
	if got := run(wake.Add(StallThreshold)); got != "true\nPASS\n" {
		t.Errorf("second process, a threshold past wake: got %q, want \"true\"", got)
	}
}

// runStalledHelper is TestStalledCrossProcess's subprocess body.
func runStalledHelper(t *testing.T) {
	t.Helper()
	ts, err := time.Parse(time.RFC3339Nano, os.Getenv("HELPER_TS"))
	if err != nil {
		t.Fatal(err)
	}
	now, err := time.Parse(time.RFC3339Nano, os.Getenv("HELPER_NOW"))
	if err != nil {
		t.Fatal(err)
	}
	s := Session{Status: Running, TS: ts}
	b, _ := json.Marshal(Stalled(s, now))
	fmt.Println(string(b))
}
