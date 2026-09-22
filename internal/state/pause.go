package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

// PauseSlack is how far a tick's wall-clock elapsed time may outrun its
// monotonic elapsed time before DetectPause treats the gap as the machine
// having slept, rather than its own tick simply running late for a real,
// awake reason (a blocked tmux call, GC, scheduler jitter - all of which
// advance the monotonic clock right alongside the wall clock, so they
// never trip this). It only needs to be comfortably larger than ordinary
// scheduling jitter and comfortably smaller than StallThreshold; it is
// not overridable via the environment the way StallThreshold is, since
// nothing about it needs to travel to a build the e2e suite drives with a
// shortened threshold.
var PauseSlack = 5 * time.Second

// DetectPause reports whether the interval between two ticks, read once
// as prev and once as now, is the signature of the machine having slept
// in between: the wall clock's account of the gap outrunning the
// monotonic clock's by more than PauseSlack.
//
// time.Time.Sub uses the monotonic reading when both operands carry one
// (see the time package's doc on monotonic clocks), and on both macOS and
// Linux that reading does not advance across a suspend: Linux's
// CLOCK_MONOTONIC and Darwin's mach_absolute_time (what runtime.nanotime
// reads on each, confirmed against both runtimes' source rather than
// assumed) are defined not to include suspended time, unlike
// CLOCK_BOOTTIME or mach_continuous_time. now.Sub(prev) is therefore the
// real, awake elapsed time, and now.Round(0).Sub(prev.Round(0)) - which
// strips the monotonic reading from both before subtracting - is the wall
// clock's own account of the same interval. A tick that was merely slow
// advances both readings by the same amount, since the process kept
// running throughout it; only a suspend leaves the monotonic one behind.
//
// prev and now must be ordinary time.Now() readings, never one that has
// been round-tripped through Round(0), Unix(), or JSON: either loses the
// monotonic reading, and Sub then silently falls back to wall-clock
// subtraction for both terms, so the gap this looks for reads as zero
// rather than being caught wrongly.
func DetectPause(prev, now time.Time) bool {
	wall := now.Round(0).Sub(prev.Round(0))
	mono := now.Sub(prev)
	return pauseGap(wall, mono)
}

// pauseGap is DetectPause's arithmetic, split out so a test can drive it
// with synthetic durations instead of a genuine wall/monotonic
// divergence: the only thing that produces one is an actual suspend,
// which a test must not induce, so supplying the two elapsed durations
// directly is what "inject the clock" means for this check.
func pauseGap(wall, mono time.Duration) bool {
	return wall-mono > PauseSlack
}

// pauseFile holds the shared "the machine just woke" marker: the most
// recent moment DetectPause fired in any client's sidebar. It is what
// makes the rebase reach a process that never watched the pause happen -
// `kido agents` (and so pi's ask_agent, which shells out to it) runs once
// per call and has no tick of its own to have missed. No extension in the
// name: readFiles (state.go) only treats a *.json entry as a candidate
// session record, so this is never mistaken for one, on top of unmarshalling
// to a Session with no Pane, which would already have excluded it.
const pauseFile = "wake"

type pauseMarker struct {
	At time.Time `json:"at"`
}

// RecordPause persists at as the new staleness baseline (see Stalled),
// but only if it is newer than whatever is already recorded: a later
// wake always supersedes an earlier one, and two sidebars - one per
// client - racing to record roughly the same wake moment must not let
// whichever writes second, but read the wake first, clobber the other
// with an older value.
func RecordPause(at time.Time) error {
	if prev, ok, err := readPause(); err == nil && ok && !at.After(prev) {
		return nil
	}
	dir := Dir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	b, err := json.Marshal(pauseMarker{At: at})
	if err != nil {
		return err
	}
	tmp := filepath.Join(dir, pauseFile+".tmp")
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, filepath.Join(dir, pauseFile))
}

// readPause reads the wake marker, if any. A missing file is not an
// error: most of the time nothing has ever paused, and Stalled treats
// that exactly like a baseline in the distant past.
func readPause() (time.Time, bool, error) {
	b, err := os.ReadFile(filepath.Join(Dir(), pauseFile))
	if err != nil {
		if os.IsNotExist(err) {
			return time.Time{}, false, nil
		}
		return time.Time{}, false, err
	}
	var m pauseMarker
	if err := json.Unmarshal(b, &m); err != nil {
		return time.Time{}, false, err
	}
	return m.At, true, nil
}
