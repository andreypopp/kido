package state

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"testing"
	"time"
)

// TestPauseGap pins DetectPause's arithmetic at the boundary: a tick
// whose wall-clock account of its own length outran its monotonic
// account by more than PauseSlack is a sleep; anything less, including a
// tick that was simply slow while the process stayed awake (wall and
// monotonic advancing together), is not.
//
// A genuine wall/monotonic divergence can only be produced by an actual
// suspend - the two clocks agree by construction whenever the process is
// actually running to observe them - so this drives pauseGap with
// synthetic durations rather than sleeping the machine.
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
// fires for two Time values that carry no monotonic reading (e.g. loaded
// from JSON, or built with time.Unix as every test clock in this repo
// is): Sub then falls back to wall-only subtraction for both terms,
// so wall - mono is always zero. Without this, a test using an injected
// clock (internal/ui's model.now) could spuriously trip DetectPause.
func TestDetectPauseDegradesWithoutMonotonic(t *testing.T) {
	prev := time.Unix(1700000000, 0)
	now := prev.Add(10 * time.Minute)
	if DetectPause(prev, now) {
		t.Error("DetectPause fired on Time values with no monotonic reading")
	}
}

// TestStalledRebasesAfterPause is requirement 2: once a pause is
// recorded, a session whose TS predates the wake is not stalled until a
// full StallThreshold has passed from the wake, not from TS - and a
// session that really is still wedged that long after waking is still
// caught. TestStalled (state_test.go) already pins the ordinary,
// no-pause boundary; this pins the same boundary shifted to the wake.
func TestStalledRebasesAfterPause(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())

	saved := StallThreshold
	StallThreshold = time.Minute
	t.Cleanup(func() { StallThreshold = saved })

	reported := time.Unix(1700000000, 0) // long before the wake
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

	// A session that reported after the wake is judged on its own TS
	// again, same as if no pause had ever been recorded.
	s.TS = wake.Add(time.Second)
	if Stalled(s, wake.Add(StallThreshold)) {
		t.Error("a session that reported after the wake was judged against the wake instead of its own TS")
	}
}

// TestRecordPauseKeepsTheLatest pins RecordPause's race guard: an older
// wake must never clobber a newer one, which is what stops two sidebars -
// one per client - racing to record roughly the same wake moment from
// letting whichever finishes last win with a stale value.
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
	got, ok, err := readPause()
	if err != nil || !ok {
		t.Fatalf("readPause: %v, %v, %v", got, ok, err)
	}
	if !got.Equal(later) {
		t.Errorf("wake marker = %v, want the later write %v to survive", got, later)
	}
}

// TestStalledCrossProcess is requirement 3 and the plan's testing note:
// the rebased verdict must reach a process that never itself detected the
// pause - ask_agent shells out to a fresh `kido agents`, once per call -
// so it has to be readable from disk by a second process, not just held
// in the sidebar's memory. It drives the standard Go "helper process"
// pattern (re-exec this same test binary in a subprocess) rather than
// building the kido binary, so it exercises exactly the state package
// function both `internal/ui` and `cmd/kido/agents.go` call.
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

	// The helper is a normal go test run under the hood, so its output
	// carries the usual trailing "PASS" line after our own printed verdict.
	if got := run(wake); got != "false\nPASS\n" {
		t.Errorf("second process, right at wake: got %q, want \"false\"", got)
	}
	if got := run(wake.Add(StallThreshold)); got != "true\nPASS\n" {
		t.Errorf("second process, a threshold past wake: got %q, want \"true\"", got)
	}
}

// runStalledHelper is TestStalledCrossProcess's subprocess body: it reads
// a Session's TS and a now from the environment (parsing PID and package
// state from flags would fight go test's own), reports Stalled for it,
// and exits - it is never run as a normal test.
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
