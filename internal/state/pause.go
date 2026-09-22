package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

// PauseSlack is how far a tick's wall-clock elapsed time may outrun its
// monotonic elapsed time before DetectPause calls the gap a sleep. It
// only needs to be comfortably larger than scheduling jitter and
// comfortably smaller than StallThreshold.
var PauseSlack = 5 * time.Second

// DetectPause reports whether the interval between two ticks, read once
// as prev and once as now, is the signature of the machine having slept
// in between: the wall clock's account of the gap outrunning the
// monotonic clock's by more than PauseSlack.
//
// time.Time.Sub uses the monotonic reading when both operands carry one,
// and on both macOS and Linux that reading does not advance across a
// suspend: Linux's CLOCK_MONOTONIC and Darwin's mach_absolute_time (what
// runtime.nanotime reads on each, confirmed against both runtimes'
// source) are defined not to include suspended time, unlike
// CLOCK_BOOTTIME or mach_continuous_time. now.Round(0).Sub(prev.Round(0))
// strips the monotonic reading from both and so is the wall clock's own
// account of the same interval.
//
// prev and now must be ordinary time.Now() readings, never one that has
// been round-tripped through Round(0), Unix(), or JSON: either loses the
// monotonic reading, and Sub then silently falls back to wall-clock
// subtraction for both terms, so the gap reads as zero.
func DetectPause(prev, now time.Time) bool {
	wall := now.Round(0).Sub(prev.Round(0))
	mono := now.Sub(prev)
	return pauseGap(wall, mono)
}

// pauseGap is DetectPause's arithmetic, split out so a test can drive it
// with synthetic durations: only an actual suspend produces a genuine
// wall/monotonic divergence.
func pauseGap(wall, mono time.Duration) bool {
	return wall-mono > PauseSlack
}

// pauseFile holds the shared "the machine just woke" marker: the most
// recent moment DetectPause fired in any client's sidebar. No .json
// extension, so readFiles never reads it as a session record.
const pauseFile = "wake"

type pauseMarker struct {
	At time.Time `json:"at"`
}

// RecordPause persists at as the new staleness baseline (see Stalled),
// but only if it is newer than whatever is already recorded, so two
// sidebars racing to record roughly the same wake cannot clobber each
// other with an older value.
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
// error: most of the time nothing has ever paused.
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
