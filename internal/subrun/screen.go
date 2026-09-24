package subrun

import "kido/internal/tmux"

// maxScreenBytes bounds a captured screen, matching internal/reap's own
// bound for the sweep's capture of a window it is about to close: this is
// exhaust for a human to read after the fact, not model input.
const maxScreenBytes = 64 * 1024

// CapturePane is tmux.CaptureScreen, indirected so a unit test can
// substitute a fake pane's screen without a real tmux server.
var CapturePane = tmux.CaptureScreen

// CaptureOwnScreen saves paneID's screen into id's run directory and
// returns what it saved. It is a run's own child capturing itself while
// its ending is still its own to record (`kido run-outcome`), which is
// why it takes one pane rather than reap.captureScreen's list: unlike the
// sweep, which runs after a window is already being collected and may
// hold a split the user added, a self-report has exactly one pane, its
// own, still alive at the moment of the call. A capture-pane error - the
// pane already gone, or tmux unreachable - is silently skipped: an ending
// must still be recorded with or without a screen to show for it.
func CaptureOwnScreen(id, paneID string) (string, bool) {
	if id == "" || paneID == "" {
		return "", false
	}
	text, err := CapturePane(paneID)
	if err != nil {
		return "", false
	}
	data := []byte(text)
	if len(data) > maxScreenBytes {
		// Keep the tail, matching reap.captureScreen: the interesting part
		// of a wedged screen is whatever came last.
		data = data[len(data)-maxScreenBytes:]
	}
	if err := WriteScreen(id, data); err != nil {
		return "", false
	}
	return string(data), true
}
