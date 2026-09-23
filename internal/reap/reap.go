// Package reap decides which subagent windows are finished with: the
// backstop behind the linger helper (`kido close-window`), run from the
// sidebar's poll (internal/ui) and from `kido reap`. What a sweep may
// close is decided from tmux's @kido_subagent mark, never from a state
// record; docs/design.md's "Window lifecycle" says why.
package reap

import (
	"os"
	"strconv"
	"strings"
	"time"

	"kido/internal/state"
	"kido/internal/subrun"
	"kido/internal/tmux"
)

// Grace is how long a finished subagent's window is left alone before a
// sweep may close it: the same read window the linger helper gives the
// user, read from the same KIDO_LINGER_SECONDS pi/kido-agents.ts reads,
// so the two halves agree.
var Grace = graceFromEnv(30 * time.Second)

func graceFromEnv(def time.Duration) time.Duration {
	if n, err := strconv.Atoi(os.Getenv("KIDO_LINGER_SECONDS")); err == nil && n > 0 {
		return time.Duration(n) * time.Second
	}
	return def
}

// window is what a sweep needs to know about one tmux window, folded out
// of the pane list.
type window struct {
	id       string
	paneIDs  []string // every pane in the window, in list-panes order
	marked   bool     // carries tmux.SubagentOption: a window kido spawn_subagent created
	runID    string   // the run id embedded in that mark, see tmux.SubagentRunID
	allDead  bool     // every pane of it is a remain-on-exit corpse
	deadTime int64    // unix time the last of them died
	focused  bool
}

// maxScreenBytes bounds a captured screen. It is far smaller than
// spawn.go's 1MB task cap - this is exhaust for a human to read after the
// fact, not model input - but big enough to hold several hundred lines of
// a typical crash; a wedged agent's scrollback could otherwise be
// arbitrarily large, and captureScreenLines (internal/tmux) only bounds
// how many lines are asked for, not how wide or how many bytes they are.
const maxScreenBytes = 64 * 1024

// capturePaneScreen is tmux.CaptureScreen, indirected so a unit test can
// substitute a fake pane's screen without a real tmux server.
var capturePaneScreen = tmux.CaptureScreen

// captureScreen saves w's panes' final screen into its run's directory,
// before mark's caller closes the window - reap.Sweep only returns a
// window id for the caller to close after this has already run. It must
// never stop a sweep from doing its job: a capture-pane error (the pane
// is already gone, or tmux itself is unreachable) is silently skipped for
// that pane, and a WriteScreen that loses a race to another sweep
// (subrun.WriteScreen's own doc) is silently discarded - either way the
// window is still closed.
//
// This runs for every window a sweep closes, not only rule 1's crashed
// ones: a cleanly finished subagent's last screen is worth keeping too,
// and there is no cheap way to tell the two apart beforehand - Died is
// only mark's own guess, written moments after this, and rule 2 closes a
// window whose subagent never got to record anything at all.
func captureScreen(w *window) {
	if w.runID == "" {
		return
	}
	var b strings.Builder
	for _, paneID := range w.paneIDs {
		text, err := capturePaneScreen(paneID)
		if err != nil {
			continue
		}
		if len(w.paneIDs) > 1 {
			// A split window: label each pane's block so a human reading
			// the file can tell them apart.
			if b.Len() > 0 {
				b.WriteByte('\n')
			}
			b.WriteString("=== " + paneID + " ===\n")
		}
		b.WriteString(text)
	}
	data := []byte(b.String())
	if len(data) == 0 {
		return
	}
	if len(data) > maxScreenBytes {
		// Keep the tail: the interesting part of a wedged agent's
		// scrollback - a crash, a traceback - is whatever came last.
		data = data[len(data)-maxScreenBytes:]
	}
	subrun.WriteScreen(w.runID, data) //nolint:errcheck // best effort, see doc comment
}

// Notice is a bash run whose ending a sweep discovered and won the
// outcome write for: nobody else is going to speak for it, so the
// caller has to tell its parent. Sweep returns these rather than
// sending anything, because a notice travels over an agent's inbox
// socket and this package has no business knowing that; what a window
// sweep can know is that a run ended with nothing said about it, which
// is the whole of what a Notice carries. cmd/kido's asyncNotice turns
// one into the text a parent reads.
type Notice struct {
	Meta    subrun.Meta
	Outcome subrun.Outcome
}

// sweptText is what a bash run's outcome says when a sweep is the one
// that found the ending. The wrapper records and notifies before it
// exits (cmd/kido/async_run.go), so it covers every ending it lives to
// see; an outcome still unwritten when the window is collected means the
// wrapper never got to speak - killed outright, or taken down with its
// window.
const sweptText = "ended without its wrapper reporting"

// Sweep returns the windows that should be closed now, in the order they
// appear in panes, and the bash runs whose parents this sweep is now
// obliged to notify (see Notice).
//
// sessions must be every live record, one entry per agent session:
// state.LoadLive or state.ReadAll. It may not be a per-pane view
// (state.Load), and "liveness is checked here" does not make one safe -
// a record the caller already dropped cannot be checked at all. Rule 2
// asks whether an instance is running anywhere, which has an answer on
// disk that no pane collision can disturb, but only if it is given every
// record. Handed a pane-keyed map it reads a parent whose pane a second
// process transiently claimed (state.beats) as a dead parent, and closes
// a healthy child's window.
//
// Two rules, both restricted to a window carrying tmux.SubagentOption:
//
//  1. every pane of a marked window is dead and has been for Grace. This
//     rule reads no state record at all.
//  2. a live subagent no live record claims as a parent is orphaned, and
//     is cancelled by closing its window. One reading of the complete
//     set decides it, so a one-shot `kido reap` applies this rule as
//     fully as the sidebar's poll does.
//
// Neither rule closes a window that is any client's current one, or a
// session's last window.
func Sweep(panes []tmux.Pane, sessions []state.Session, now time.Time) ([]string, []Notice) {
	if !anyMarked(panes) {
		// Nothing kido spawn_subagent created is on screen, so neither rule can
		// close anything. The common case on a machine with no subagents
		// running, and this runs on every sidebar tick.
		return nil, nil
	}
	windows, byID, byPane := foldWindows(panes)

	closing := map[string]bool{}
	var out []string
	var notices []Notice
	mark := func(id string) {
		w, ok := byID[id]
		if !ok || closing[id] || !w.marked || w.focused || tmux.LastWindow(panes, id) {
			return
		}
		closing[id] = true
		if w.runID != "" {
			captureScreen(w)
			if n, ok := recordEnding(w.runID, now); ok {
				notices = append(notices, n)
			}
		}
		out = append(out, id)
	}

	for _, w := range windows {
		if w.allDead && w.deadTime > 0 && now.Sub(time.Unix(w.deadTime, 0)) >= Grace {
			mark(w.id) // rule 1
		}
	}

	live := map[string]bool{} // Instance of every agent still running
	for _, s := range sessions {
		if s.Instance != "" && state.Alive(s.PID) {
			live[s.Instance] = true
		}
	}

	for _, s := range sessions {
		// A dead subagent is rule 1's business: acting on its record here
		// would let a state file left by a previous tmux server close a
		// window by pane id alone.
		if s.ParentInstance == "" || !state.Alive(s.PID) {
			continue
		}
		if live[s.ParentInstance] {
			continue
		}
		if id, ok := byPane[s.Pane]; ok {
			mark(id) // rule 2
		}
	}
	return out, notices
}

// recordEnding writes the outcome for the run in a window a sweep is
// about to close, and reports whether that run's parent is now this
// sweep's to tell.
//
// The outcome write is the arbiter and the only one: it is O_EXCL, so a
// sweep that loses it to the run's own wrapper, to `kido stop_subagent`
// or to a second sidebar sweeping the same window returns false and
// stays quiet, and exactly one observer of any ending ever speaks.
//
// Only a bash run is spoken for. An agent's completion is a judgement
// only the model can make, and docs/design.md is deliberate that a
// subagent which crashes without calling notify_parent tells its parent
// nothing; a bash run's completion is an exit code, and the two are not
// the same case. An agent run keeps the Died it always got.
func recordEnding(runID string, now time.Time) (Notice, bool) {
	meta, err := subrun.ReadMeta(runID)
	bash := err == nil && meta.EffectiveKind() == subrun.KindBash

	o := subrun.Outcome{Result: subrun.Died, At: now}
	if bash {
		o = subrun.Outcome{Result: subrun.Failed, Text: sweptText, At: now}
	}
	if err := subrun.RecordOutcome(runID, o); err != nil {
		return Notice{}, false //nolint:nilerr // losing the write is the ordinary case, not a failure
	}
	if !bash || meta.ParentInstance == "" {
		return Notice{}, false
	}
	return Notice{Meta: meta, Outcome: o}, true
}

// anyMarked reports whether any pane belongs to a window kido spawn_subagent
// created, the precondition both rules share.
func anyMarked(panes []tmux.Pane) bool {
	for _, p := range panes {
		if p.Subagent != "" {
			return true
		}
	}
	return false
}

// foldWindows collapses panes into one entry per window, in the order the
// windows first appear, plus lookups by window id and by pane id.
func foldWindows(panes []tmux.Pane) ([]*window, map[string]*window, map[string]string) {
	var windows []*window
	byID := map[string]*window{}
	byPane := map[string]string{}
	for _, p := range panes {
		byPane[p.PaneID] = p.WindowID
		w, ok := byID[p.WindowID]
		if !ok {
			w = &window{id: p.WindowID, allDead: true}
			byID[p.WindowID] = w
			windows = append(windows, w)
		}
		w.paneIDs = append(w.paneIDs, p.PaneID)
		if p.Subagent != "" {
			w.marked = true
			w.runID = tmux.SubagentRunID(p.Subagent)
		}
		// A split window is finished only once all of it is: a subagent
		// that split its own window and left something running in the
		// other pane is still working.
		if !p.Dead {
			w.allDead = false
		}
		if p.DeadTime > w.deadTime {
			w.deadTime = p.DeadTime
		}
		if p.Watched() {
			w.focused = true // tmux.WindowFocused, for a window already folded
		}
	}
	return windows, byID, byPane
}
