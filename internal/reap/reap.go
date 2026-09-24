// Package reap decides which subagent panes are finished with: the
// backstop behind the linger helper (`kido close-run`), run from the
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
	id      string
	paneIDs []string // every pane in the window, in list-panes order
	marked  bool     // carries tmux.SubagentOption: a window kido spawn_subagent created
	runID   string   // the run id embedded in that mark, see tmux.SubagentRunID
	// runPane is the pane the run itself is in, from
	// tmux.SubagentPaneOption, and "" for a window marked by a kido from
	// before that option existed. Its own death is what rule 1 reads;
	// allDead/deadTime are the fallback for a window with no such pane.
	runPane     string
	runPaneDead bool
	runDeadTime int64
	allDead     bool  // every pane of it is a remain-on-exit corpse
	deadTime    int64 // unix time the last of them died
	focused     bool
}

// Close is one thing a sweep wants closed, and the unit is the run's
// pane: a window is only ever the user's, and what kido put in it is one
// pane of it. PaneID is that pane; it is "" when the window itself is
// what is to be closed - the run's pane is all the window has, or the
// window was marked before kido knew which pane the run was in. The two
// are not interchangeable even when a window has one pane: only closing
// a window can destroy a session, and only that case is held to the
// last-window refusal.
type Close struct {
	WindowID string
	PaneID   string
}

// Window reports whether c asks for the whole window rather than one
// pane of it.
func (c Close) Window() bool { return c.PaneID == "" }

// Ops are the tmux acts a Close is carried out with. Every caller
// indirects them for its own tests - internal/ui and cmd/kido each keep
// their own set - so Release takes them rather than reaching for tmux
// itself.
type Ops struct {
	KillWindow func(string) error
	KillPane   func(string) error
	Unmark     func(string) error
}

// Release carries out c against a server whose panes are panes: close
// the window when the run was all of it, or kill the run's own pane and
// hand the window back to whatever the user left in it. Unmarking is
// what stops the tree nesting that window, switch-window skipping it and
// a later sweep considering it.
//
// It is every collector's one act - the sidebar's sweep, `kido reap`,
// `kido close-run` and the kill `kido stop_subagent` degrades to - so
// "kill the run's pane, then unmark unless that pane was the window's
// last" has one spelling. A Close from Sweep never needs that last
// exception, since mark already promotes a lone pane to a window close;
// a caller that found the run's pane some other way does.
//
// What comes back is the kill's error, which is the act that either
// happened or did not. The unmark is best effort: the window may have
// gone between the listing and now, and a mark left on a window nobody
// can find is not a reason to call a collected run uncollected.
func (o Ops) Release(panes []tmux.Pane, c Close) error {
	if c.Window() {
		return o.KillWindow(c.WindowID)
	}
	err := o.KillPane(c.PaneID)
	if !tmux.LastPane(panes, c.WindowID) {
		o.Unmark(c.WindowID) //nolint:errcheck // best effort, see doc comment
	}
	return err
}

// captureScreen saves the final screen of the panes a sweep is about to
// close into runID's directory, before mark's caller closes anything -
// reap.Sweep only returns a Close for the caller to act on after this has
// already run. It must never stop a sweep from doing its job: a
// capture-pane error (the pane is already gone, or tmux itself is
// unreachable) is silently skipped for that pane, and a WriteScreen that
// loses a race to another sweep (subrun.WriteScreen's own doc) is
// silently discarded - either way the pane is still closed.
//
// paneIDs is what is being closed and not the whole window: a pane the
// user split off is theirs and no part of the run's last screen.
//
// This runs for every ending a sweep collects, not only rule 1's crashed
// ones: a cleanly finished subagent's last screen is worth keeping too,
// and there is no cheap way to tell the two apart beforehand - Died is
// only mark's own guess, written moments after this, and rule 2 closes a
// pane whose subagent never got to record anything at all.
func captureScreen(runID string, paneIDs []string) {
	if runID == "" {
		return
	}
	var b strings.Builder
	for _, paneID := range paneIDs {
		text, err := subrun.CapturePane(paneID)
		if err != nil {
			continue
		}
		if len(paneIDs) > 1 {
			// A split window: label each pane's block so a human reading
			// the file can tell them apart.
			if b.Len() > 0 {
				b.WriteByte('\n')
			}
			b.WriteString("=== " + paneID + " ===\n")
		}
		b.WriteString(text)
	}
	data := subrun.TruncateScreen([]byte(b.String()))
	if len(data) == 0 {
		return
	}
	subrun.WriteScreen(runID, data) //nolint:errcheck // best effort, see doc comment
}

// Notice is a run whose ending a sweep discovered and won the outcome
// write for: nobody else is going to speak for it, so the caller has to
// tell its parent. Sweep returns these rather than sending anything,
// because a notice travels over an agent's inbox socket and this package
// has no business knowing that; what a sweep can know is that a run
// ended with nothing said about it, which is the whole of what a
// Notice carries. cmd/kido's endingNotice turns one into the text a
// parent reads.
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

// Sweep returns what should be closed now, in the order it appears in
// panes, and the runs whose parents this sweep is now obliged to notify
// (see Notice).
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
//  1. the run's own pane is dead and has been for Grace. This rule reads
//     no state record at all. A window marked before
//     tmux.SubagentPaneOption existed has no run pane to single out, and
//     falls back to the older rule: every pane of it is dead, and the
//     window is the unit.
//  2. a live subagent no live record claims as a parent is orphaned, and
//     is cancelled by closing the pane it runs in. One reading of the
//     complete set decides it, so a one-shot `kido reap` applies this
//     rule as fully as the sidebar's poll does.
//
// Neither rule touches a window that is any client's current one - the
// user may be reading the very pane that would go - and neither closes a
// session's last window.
func Sweep(panes []tmux.Pane, sessions []state.Session, now time.Time) ([]Close, []Notice) {
	if !anyMarked(panes) {
		// Nothing kido spawn_subagent created is on screen, so neither rule can
		// close anything. The common case on a machine with no subagents
		// running, and this runs on every sidebar tick.
		return nil, nil
	}
	windows, byID, byPane := foldWindows(panes)

	closing := map[string]bool{}
	var out []Close
	var notices []Notice
	// mark takes the run's pane, or "" for a window that is the unit
	// itself; a pane that is all its window has is promoted to a window
	// close, since killing it closes the window anyway and the refusal
	// that guards a session belongs on that act.
	mark := func(id, paneID string) {
		w, ok := byID[id]
		if !ok || closing[id] || !w.marked || w.focused {
			return
		}
		if len(w.paneIDs) == 1 {
			paneID = ""
		}
		if paneID == "" && tmux.LastWindow(panes, id) {
			return
		}
		closing[id] = true
		if w.runID != "" {
			going := []string{paneID}
			if paneID == "" {
				going = w.paneIDs
			}
			captureScreen(w.runID, going)
			if n, ok := recordEnding(w.runID, now); ok {
				notices = append(notices, n)
			}
		}
		out = append(out, Close{WindowID: id, PaneID: paneID})
	}

	for _, w := range windows {
		if !w.marked { // rule 1
			continue
		}
		if w.runPane != "" {
			if w.runPaneDead && w.runDeadTime > 0 && now.Sub(time.Unix(w.runDeadTime, 0)) >= Grace {
				mark(w.id, w.runPane)
			}
			continue
		}
		if w.allDead && w.deadTime > 0 && now.Sub(time.Unix(w.deadTime, 0)) >= Grace {
			mark(w.id, "")
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
			// The child's own pane, which is the run's: its record is what
			// names it, so this rule needs no pane option to find it.
			mark(id, s.Pane) // rule 2
		}
	}
	return out, notices
}

// RecordEnding writes o as the ending of meta's run and reports the
// notice the run's parent is owed, if this writer is the one that has to
// send it. Every observer that discovers an ending from outside the run
// goes through here - a sweep, `kido stop_subagent` - so a third finds a
// call site rather than reimplementing the invariant. The run's own
// wrapper is the exception and writes for itself: it holds no meta file,
// and it is the one observer that can tell a write failing from a write
// lost and says so on stderr (cmd/kido/async_run.go).
//
// The outcome write is the arbiter and the only one: it is O_EXCL, so an
// observer that loses it to another returns false and stays quiet, and
// exactly one observer of any ending ever speaks.
//
// Both kinds of run are spoken for. What the notice claims is only that
// the run ended and nothing was said about it - never a verdict on an
// agent's work, which is a judgement only the model can make and which
// is why notify_parent exists. A run nobody started is told to nobody.
func RecordEnding(meta subrun.Meta, o subrun.Outcome) (Notice, bool) {
	if err := subrun.RecordOutcome(meta.ID, o); err != nil {
		return Notice{}, false //nolint:nilerr // losing the write is the ordinary case, not a failure
	}
	if meta.ParentInstance == "" {
		return Notice{}, false
	}
	return Notice{Meta: meta, Outcome: o}, true
}

// recordEnding is RecordEnding for the run a sweep is about to collect:
// the sweep is the observer that has to guess what happened,
// and what it may guess depends on the kind. A bash run ended without
// its wrapper reporting; an agent run keeps the Died it always got, and
// the notice says only that nobody reported it.
func recordEnding(runID string, now time.Time) (Notice, bool) {
	meta, err := subrun.ReadMeta(runID)
	if err != nil {
		// No meta is an agent-shaped run as far as every reader of it is
		// concerned (subrun.EffectiveKind), and one with nobody to tell.
		meta = subrun.Meta{ID: runID}
	}
	o := subrun.Outcome{Result: subrun.Died, At: now}
	if meta.EffectiveKind() == subrun.KindBash {
		o = subrun.Outcome{Result: subrun.Failed, Text: sweptText, At: now}
	}
	return RecordEnding(meta, o)
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
		if p.SubagentPane != "" {
			w.runPane, w.runPaneDead, w.runDeadTime = p.PaneID, p.Dead, p.DeadTime
		}
		// The fallback for a window with no run pane to single out: it is
		// finished only once all of it is, since nothing tells the run's own
		// pane from one the user split off later. One of three halves of that
		// old-mark fallback - the others are runPaneOf (cmd/kido/closerun.go)
		// and tmux.WindowAllDead - which go together or not at all.
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
