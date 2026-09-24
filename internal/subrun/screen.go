package subrun

import "kido/internal/tmux"

// MaxScreenBytes bounds a captured screen, whoever captured it - a run
// reporting its own ending here, or the sweep capturing a window it is
// about to close (internal/reap). It is far smaller than
// spawn_subagent's 1MB task cap - this is exhaust for a human to read
// after the fact, not model input - but big enough to hold several
// hundred lines of a typical crash; a wedged agent's scrollback could
// otherwise be arbitrarily large, and captureScreenLines (internal/tmux)
// only bounds how many lines are asked for, not how wide or how many
// bytes they are.
const MaxScreenBytes = 64 * 1024

// TruncateScreen cuts data to MaxScreenBytes, keeping the tail: the
// interesting part of a wedged screen - a crash, a traceback - is
// whatever came last.
func TruncateScreen(data []byte) []byte {
	if len(data) > MaxScreenBytes {
		return data[len(data)-MaxScreenBytes:]
	}
	return data
}

// CapturePane is tmux.CaptureScreen, indirected so a unit test can
// substitute a fake pane's screen without a real tmux server. Both
// captures go through it, this package's and internal/reap's.
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
	data := TruncateScreen([]byte(text))
	if err := WriteScreen(id, data); err != nil {
		return "", false
	}
	return string(data), true
}
