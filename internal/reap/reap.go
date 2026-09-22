// Package reap decides which subagent windows are finished with: the
// backstop behind the linger helper (`kido close-window`), run from the
// sidebar's poll (internal/ui) and from `kido reap`. What a sweep may
// close is decided from tmux's @kido_subagent mark, never from a state
// record; docs/design.md's "Window lifecycle" says why.
package reap

import (
	"os"
	"strconv"
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
	marked   bool   // carries tmux.SubagentOption: a window kido spawn created
	runID    string // the run id embedded in that mark, see tmux.SubagentRunID
	allDead  bool   // every pane of it is a remain-on-exit corpse
	deadTime int64  // unix time the last of them died
	focused  bool
}

// Sweep returns the windows that should be closed now, in the order they
// appear in panes. sessions may come from state.Load or state.ReadAll;
// liveness is checked here rather than assumed, so both give the same
// answer.
//
// Two rules, both restricted to a window carrying tmux.SubagentOption:
//
//  1. every pane of a marked window is dead and has been for Grace. This
//     rule reads no state record at all.
//  2. a live subagent whose parent is gone is cancelled by closing its
//     window.
//
// Neither rule closes a window that is any client's current one, or a
// session's last window.
func Sweep(panes []tmux.Pane, sessions []state.Session, now time.Time) []string {
	windows, byID, byPane := foldWindows(panes)

	closing := map[string]bool{}
	var out []string
	mark := func(id string) {
		w, ok := byID[id]
		if !ok || closing[id] || !w.marked || w.focused || tmux.LastWindow(panes, id) {
			return
		}
		closing[id] = true
		if w.runID != "" {
			subrun.RecordOutcome(w.runID, subrun.Outcome{Result: subrun.Died, At: now}) //nolint:errcheck // best effort
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
		if s.ParentInstance == "" || !state.Alive(s.PID) || live[s.ParentInstance] {
			continue
		}
		if id, ok := byPane[s.Pane]; ok {
			mark(id) // rule 2
		}
	}
	return out
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
