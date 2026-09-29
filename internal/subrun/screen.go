package subrun

import "kido/internal/tmux"

// MaxScreenBytes bounds a captured screen, whoever captured it - a run
// reporting its own ending here, or the sweep capturing a window it is
// about to close (internal/reap). This is exhaust for a human to read
// after the fact, not model input, so it is far smaller than
// spawn_subagent's 1MB task cap but big enough for several hundred
// lines of a typical crash.
const MaxScreenBytes = 64 * 1024

// TruncateScreen cuts data to MaxScreenBytes, keeping the tail: the
// interesting part of a wedged screen is whatever came last.
func TruncateScreen(data []byte) []byte {
	if len(data) > MaxScreenBytes {
		return data[len(data)-MaxScreenBytes:]
	}
	return data
}

// CapturePane is tmux.CaptureScreen, indirected so a unit test can
// substitute a fake pane's screen without a real tmux server.
var CapturePane = tmux.CaptureScreen

// CaptureOwnScreen saves paneID's screen into id's run directory and
// returns what it saved: a run's own child capturing itself, one pane
// rather than reap.captureScreen's list, while its ending is still its
// own to record. A capture-pane error is silently skipped: an ending
// must still be recorded with or without a screen to show for it.
func CaptureOwnScreen(id ID, paneID string) (string, bool) {
	if id == "" || paneID == "" {
		return "", false
	}
	text, err := CapturePane(paneID)
	if err != nil {
		return "", false
	}
	data := TruncateScreen([]byte(text))
	if err := WriteScreen(id, data); err != nil {
		return "", false
	}
	return string(data), true
}
