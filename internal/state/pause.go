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

// DetectPause reports whether the gap between two ticks is the signature
// of the machine having slept: the wall clock's account of the interval
// outrunning the monotonic clock's by more than PauseSlack. On both
// macOS and Linux the monotonic reading (Darwin's mach_absolute_time,
// Linux's CLOCK_MONOTONIC) does not advance across a suspend, unlike the
// wall clock; now.Round(0).Sub(prev.Round(0)) strips the monotonic
// reading to get the wall clock's own account.
//
// prev and now must be plain time.Now() readings: one round-tripped
// through Round(0), Unix() or JSON loses its monotonic reading, and Sub
// then falls back to wall-clock subtraction for both terms, reading the
// gap as zero.
func DetectPause(prev, now time.Time) bool {
	wall := now.Round(0).Sub(prev.Round(0))
	mono := now.Sub(prev)
	return pauseGap(wall, mono)
}

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

// RecordPause persists at as the new staleness baseline, but only if
// newer than what is already recorded, so two sidebars racing to record
// the same wake cannot clobber each other with an older value.
func RecordPause(at time.Time) error {
	if prev := Wake(); !at.After(prev) {
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
