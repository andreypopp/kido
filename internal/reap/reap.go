// Package reap decides which subagent windows are finished with, and is
// the backstop half of the window lifecycle in docs/subagents-plan.md.
//
// The primary mechanism is the linger helper a subagent spawns before it
// exits (`kido close-window`, cmd/kido/closewindow.go). It never runs at
// all when the subagent dies by SIGKILL or an OOM kill, and it skips a
// window the user is reading, so something outside the subagent has to
// sweep up after it. That sweep is Sweep, run from the sidebar's own poll
// (internal/ui) and from `kido reap` (cmd/kido/reap.go).
//
// What a sweep may close is decided from tmux, not from kido's state
// directory. An earlier design read the state record of a dead subagent
// and closed the window its pane was in, which cannot work: internal/ui
// calls state.Load every 100ms and Load deletes a dead-pid record as a
// side effect of reading it, so with a sidebar running - the normal case
// - the record is gone within a tick of the process dying, long before
// any sweep sees it. The @kido_subagent window option kido spawn sets
// (tmux.SubagentOption) has neither problem: it lives in the tmux server,
// nothing races it away, and it can only ever name a window kido itself
// created.
package reap

import (
	"os"
	"strconv"
	"time"

	"kido/internal/state"
	"kido/internal/tmux"
)

// Grace is how long a finished subagent's window is left alone before a
// sweep may close it: the same read-it-before-it-goes window the linger
// helper gives the user, since a sweep that fired the instant the pane
// died would close windows out from under the linger it exists to back
// up. Read from the environment because the two halves of the lifecycle
// run in different processes - this one in the sidebar, the helper's own
// delay in pi/kido-status.ts, which reads the same variable - and a test
// must be able to shorten both without waiting out a real 30 seconds.
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
	marked   bool  // carries tmux.SubagentOption: a window kido spawn created
	allDead  bool  // every pane of it is a remain-on-exit corpse
	deadTime int64 // unix time the last of them died
	focused  bool
}

// Sweep returns the windows that should be closed now, in the order they
// appear in panes. sessions is every state record the caller has - live
// ones at least; a caller reading through state.Load has only those, one
// reading through state.ReadAll has the dead ones too, and both give the
// same answers here because liveness is checked rather than assumed.
//
// Two rules, and both of them may only ever close a window carrying
// tmux.SubagentOption:
//
//  1. every pane of a marked window is dead and has been for Grace. The
//     subagent is finished, by exit or by SIGKILL, and its window is the
//     corpse remain-on-exit left behind. This rule reads no state record
//     at all, which is what makes it work in a session with a sidebar
//     running (see the package comment) and what makes it safe against
//     pane ids: a state file outlives the tmux server that issued the
//     pane id it names, and %0 on the next server belongs to somebody
//     else entirely - but a window that is both marked and dead is this
//     server's own answer about itself.
//
//  2. a live subagent whose parent is gone is cancelled by closing its
//     window - a forced stop rather than the graceful shutdown the poll
//     in pi/kido-status.ts asks for, but the only lever a process outside
//     pi has. This one needs the record, since nothing in tmux knows who
//     spawned whom; the mark is what keeps a stale record naming a
//     recycled pane id from closing an unrelated window.
//
// A window that is any client's current one is never closed by either
// rule. The user may have switched to it to read the subagent's last
// screen, which is exactly what `kido close-window` refuses for, and a
// sweep that overrode that refusal would make it meaningless. Nothing is
// lost by waiting: a sweep runs again on the next poll, so the window is
// collected as soon as the user leaves it.
func Sweep(panes []tmux.Pane, sessions []state.Session, now time.Time) []string {
	windows, byID, byPane := foldWindows(panes)

	closing := map[string]bool{}
	var out []string
	// The guards every rule shares: a window nobody marked is not kido's
	// to close, a window the user is reading is not closed out from under
	// them, and a session's last window is not closed at all.
	mark := func(id string) {
		w, ok := byID[id]
		if !ok || closing[id] || !w.marked || w.focused || tmux.LastWindow(panes, id) {
			return
		}
		closing[id] = true
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
		// A record with no ParentInstance is a root agent - the user's own
		// pane - and is nobody's to cancel. A dead subagent is rule 1's
		// business, and acting on its record here is what would let a
		// state file left by a previous tmux server close a window by
		// pane id alone.
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
