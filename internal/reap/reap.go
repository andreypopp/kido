// Package reap decides which subagent panes are finished with: the
// backstop behind the linger helper (`kido close-run`), run from the
// sidebar's poll (internal/ui) and from `kido reap`. What a sweep may
// close is decided from tmux's @kido_run option, never from a state
// record; docs/design.md's "Window lifecycle" says why.
package reap

import (
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"kido/internal/msg"
	"kido/internal/state"
	"kido/internal/subrun"
	"kido/internal/tmux"
)

// Grace is how long a finished subagent's window is left alone before a
// sweep may close it: the same read window the linger helper gives the
// user, read from the same KIDO_LINGER_SECONDS pi/kido-agents.ts reads,
// so the two halves agree.
var Grace = func() time.Duration {
	if n, err := strconv.Atoi(os.Getenv("KIDO_LINGER_SECONDS")); err == nil && n > 0 {
		return time.Duration(n) * time.Second
	}
	return 30 * time.Second
}()

// window is what a sweep needs to know about one tmux window, folded out
// of the pane list.
type window struct {
	id      string
	paneIDs []string // every pane in the window, in list-panes order
	// run is the pane carrying tmux.RunOption - the pane kido
	// spawn_subagent actually runs the run in - or the zero Pane if this
	// window has none. Its DeadAt is what rule 1 reads.
	run     tmux.Pane
	focused bool
}

// Close is one thing a sweep wants closed, and the unit is the run's
// pane: a window is only ever the user's, and what kido put in it is one
// pane of it. PaneID is that pane; it is "" when the window itself is
// what is to be closed - the run's pane is all the window has. The two
// are not interchangeable even when a window has one pane: only closing
// a window can destroy a session, and only that case is held to the
// last-window refusal.
type Close struct {
	WindowID string
	PaneID   string
}

// Ops are the tmux acts a Close is carried out with. Every caller
// indirects them for its own tests - internal/ui and cmd/kido each keep
// their own set - so Release takes them rather than reaching for tmux
// itself.
type Ops struct {
	KillWindow func(string) error
	KillPane   func(string) error
}

// Release carries out c against a server whose panes are panes: close
// the window when the run was all of it, or kill the run's own pane and
// hand the window back to whatever the user left in it. RunOption is
// pane-scoped, so killing the run's pane clears it with no separate
// unmark step: the tree, switch-window and a later sweep all stop
// considering the window the instant tmux itself drops the pane.
//
// It is every collector's one act - the sidebar's sweep, `kido reap`,
// `kido close-run` and the kill `kido stop_subagent` degrades to.
func (o Ops) Release(c Close) error {
	if c.PaneID == "" {
		return o.KillWindow(c.WindowID)
	}
	return o.KillPane(c.PaneID)
}

// Decide is `kido close-run`'s decision for windowID: the Close to
// release, or a refusal explaining why nothing was done. A refusal is
// not an error - every reason here is an ordinary skip, left for a later
// sweep or for the user to finish reading.
func Decide(panes []tmux.Pane, windowID string) (Close, string) {
	if tmux.WindowFocused(panes, windowID) {
		return Close{}, fmt.Sprintf("%s is a client's current window; leaving it for the user to read", windowID)
	}
	runPane, ok := tmux.RunPane(panes, windowID)
	if ok && runPane.DeadAt == 0 {
		return Close{}, fmt.Sprintf("%s's run is still going; leaving it", windowID)
	}
	if ok && !tmux.LastPane(panes, windowID) {
		// The user's own split is in there, so what is collected is the
		// run's pane and the window becomes theirs.
		return Close{WindowID: windowID, PaneID: runPane.PaneID}, ""
	}
	if !ok {
		return Close{}, fmt.Sprintf("%s has no run pane; leaving it", windowID)
	}
	// Verified against a real server: kill-window on a session's last
	// window ends the session and every client attached to it.
	if tmux.LastWindow(panes, windowID) {
		return Close{}, fmt.Sprintf("%s is its session's only window; closing it would destroy the session", windowID)
	}
	return Close{WindowID: windowID}, ""
}

// Collect is one full sweep: what Sweep finds, released, then whichever
// endings this caller won and must now tell the parent about. It is the
// loop the sidebar's poll and `kido reap` both ran by hand before this
// moved here - Sweep, Release, Send - now the one place either can call.
func Collect(panes []tmux.Pane, sessions []state.Session, now time.Time, ops Ops) {
	closing, endings := Sweep(panes, sessions, now)
	// Every close is best effort - another sweep, or the linger helper, may
	// have got there first, and each of them is racing the others by design.
	for _, c := range closing {
		ops.Release(c) //nolint:errcheck // best effort, see above
	}
	// After the closes, because this is the one observer that may block: a
	// notice is a socket round trip to an agent that might be wedged, and
	// the window it describes is better closed first.
	for _, e := range endings {
		e.Send() //nolint:errcheck // best effort; the outcome is already recorded
	}
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
func captureScreen(runID subrun.ID, paneIDs []string) {
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

// maxNoticeTailBytes is how much of a bash run's output its ending
// notice carries. The tail, not the head: what a failure has to say, it
// says last.
const maxNoticeTailBytes = 4000

// Ending is a run whose ending a sweep discovered and won the outcome
// write for, or one `kido run-outcome`/`kido stop_subagent` built for
// itself: nobody else is going to speak for it, so this is what tells
// its parent. Detail is a BashEnding iff Meta.Kind == subrun.KindBash,
// by construction - RecordEnding is the one place that builds an Ending
// from a bare Meta and Outcome, and it picks the Detail from Meta.Kind.
type Ending struct {
	Meta    subrun.Meta
	Outcome subrun.Outcome
	Detail  EndingDetail
}

// EndingDetail is what an Ending's Send says beyond the outcome every
// run shares: a bash run's output, or an agent run's own record of
// whether it spoke for itself.
type EndingDetail interface{ body(Ending) string }

// BashEnding is a `kido async_bash` run's own half of an ending notice.
// Unstreamed is how many of the run's output lines never reached the
// parent while it ran (--stream only; zero for every other sender and
// every other observer of an ending). Reported because a model that
// watched output arrive would otherwise have no way to know it was
// watching part of it.
type BashEnding struct{ Unstreamed int }

// AgentEnding is a `kido spawn_subagent` run's own half of an ending
// notice. Unreported is the child's own word that it never called
// notify_parent (`kido run-outcome --unreported`). Only the child can
// know it; every other observer of an agent run's ending leaves it
// false and says nothing either way about a report.
type AgentEnding struct{ Unreported bool }

// label names a run wherever an Ending speaks of it - in the notice, and
// as the notice's own sender. A run nobody named is its own id, which is
// at least addressable.
func (e Ending) label() string {
	if e.Meta.Name == "" {
		return string(e.Meta.ID)
	}
	return e.Meta.Name
}

// Send delivers e to the run's parent, as a notice envelope over its
// inbox. The outcome is already on disk by the time this runs, so a
// failure here costs the notice and nothing else.
//
// A run nobody started has nobody to tell - a `kido async_bash` typed at
// a human's shell has no parent session at all - and msg.Notify's own
// refusal would only print to a pane that is about to close.
func (e Ending) Send() error {
	if e.Meta.ParentSession == "" {
		return nil
	}
	return msg.Notify(e.Meta.ParentSession, msg.From{Name: e.label()}, e.Detail.body(e))
}

func (d BashEnding) body(e Ending) string {
	var b strings.Builder
	fmt.Fprintf(&b, "async run %q %s: %s\n", e.label(), e.Outcome.Result, e.Outcome.Text)
	fmt.Fprintf(&b, "run: %s\n", e.Meta.ID)
	fmt.Fprintf(&b, "output: %s\n", subrun.OutputPath(e.Meta.ID))
	if d.Unstreamed > 0 {
		fmt.Fprintf(&b, "%d lines not streamed (the output file above has every one)\n", d.Unstreamed)
	}
	tail, omitted, err := tailOfFile(subrun.OutputPath(e.Meta.ID), maxNoticeTailBytes)
	switch {
	case err != nil:
		fmt.Fprintf(&b, "--- output unreadable: %v ---", err)
	case tail == "":
		fmt.Fprint(&b, "--- no output ---")
	case omitted > 0:
		fmt.Fprintf(&b, "--- last %d bytes of output (%d omitted) ---\n%s", len(tail), omitted, tail)
	default:
		fmt.Fprintf(&b, "--- output ---\n%s", tail)
	}
	return b.String()
}

// body is the notice for a subagent run whose ending the child did not
// record as a reported one. It claims nothing about the work: the first
// line is the only verdict there is, and the rest is what a parent needs
// to do something about it, the run id and the session to pick up where
// it stopped. The verdict is the child's own when it vouched for its
// silence; a sweep knows only that the run ended with no outcome of its
// own, which is no evidence of silence.
func (d AgentEnding) body(e Ending) string {
	var b strings.Builder
	if d.Unreported {
		fmt.Fprintf(&b, "subagent %q %s without reporting: it never called notify_parent, so this is the whole account of it\n", e.label(), e.Outcome.Result)
	} else {
		fmt.Fprintf(&b, "subagent %q ended without recording an outcome of its own, so kido recorded it as %s; whether it called notify_parent is not known, and any report it sent stands\n", e.label(), e.Outcome.Result)
	}
	if e.Outcome.Text != "" {
		fmt.Fprintf(&b, "detail: %s\n", e.Outcome.Text)
	}
	fmt.Fprintf(&b, "run: %s\n", e.Meta.ID)
	fmt.Fprintf(&b, "resume: spawn_subagent(resume: %q)\n", e.Meta.ID)
	return b.String()
}

// tailOfFile returns the last max bytes of path and how many bytes were
// dropped from the front of it. The cut is moved forward off a partial
// UTF-8 rune and anything still invalid is replaced, because a notice
// that is not valid UTF-8 is refused by the send path outright - and a
// build log ending mid-character is an ordinary way for that to happen.
func tailOfFile(path string, max int64) (string, int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return "", 0, err
	}
	var omitted int64
	if fi.Size() > max {
		omitted = fi.Size() - max
		if _, err := f.Seek(omitted, io.SeekStart); err != nil {
			return "", 0, err
		}
	}
	b, err := io.ReadAll(f)
	if err != nil {
		return "", 0, err
	}
	if omitted > 0 {
		before := len(b)
		for len(b) > 0 && !utf8.RuneStart(b[0]) {
			b = b[1:]
		}
		omitted += int64(before - len(b))
	}
	return strings.ToValidUTF8(string(b), "\uFFFD"), omitted, nil
}

// Sweep returns what should be closed now, in the order it appears in
// panes, and the runs whose parents this sweep is now obliged to notify
// (see Ending).
//
// sessions must be every live record, one entry per agent session:
// state.LoadLive or state.ReadAll. It may not be a per-pane view
// (state.Load), and "liveness is checked here" does not make one safe -
// a record the caller already dropped cannot be checked at all. Rule 2
// asks whether a session is running anywhere, which has an answer on
// disk that no pane collision can disturb, but only if it is given every
// record. Handed a pane-keyed map it reads a parent whose pane a second
// process transiently claimed (state.beats) as a dead parent, and closes
// a healthy child's window.
//
// Two rules, both restricted to a window carrying a run pane
// (tmux.RunOption):
//
//  1. the run's own pane is dead and has been for Grace. This rule reads
//     no state record at all.
//  2. a live subagent no live record claims as a parent is orphaned, and
//     is cancelled by closing the pane it runs in. One reading of the
//     complete set decides it, so a one-shot `kido reap` applies this
//     rule as fully as the sidebar's poll does.
//
// Neither rule touches a window that is any client's current one - the
// user may be reading the very pane that would go - and neither closes a
// session's last window.
func Sweep(panes []tmux.Pane, sessions []state.Session, now time.Time) ([]Close, []Ending) {
	if !anyRunPane(panes) {
		// Nothing kido spawn_subagent created is on screen, so neither rule can
		// close anything. The common case on a machine with no subagents
		// running, and this runs on every sidebar tick.
		return nil, nil
	}
	windows, byID, byPane := foldWindows(panes)

	closing := map[string]bool{}
	var out []Close
	var endings []Ending
	// mark takes the run's pane, or "" for a window that is the unit
	// itself; a pane that is all its window has is promoted to a window
	// close, since killing it closes the window anyway and the refusal
	// that guards a session belongs on that act.
	mark := func(id, paneID string) {
		w, ok := byID[id]
		if !ok || closing[id] || w.run.PaneID == "" || w.focused {
			return
		}
		if len(w.paneIDs) == 1 {
			paneID = ""
		}
		if paneID == "" && tmux.LastWindow(panes, id) {
			return
		}
		runID, err := subrun.ParseID(w.run.Run)
		if err != nil {
			return
		}
		closing[id] = true
		going := []string{paneID}
		if paneID == "" {
			going = w.paneIDs
		}
		captureScreen(runID, going)
		if e, ok := recordEnding(runID, now); ok {
			endings = append(endings, e)
		}
		out = append(out, Close{WindowID: id, PaneID: paneID})
	}

	for _, w := range windows {
		if w.run.PaneID == "" { // rule 1 needs a run pane to check
			continue
		}
		if w.run.DeadAt > 0 && now.Sub(time.Unix(w.run.DeadAt, 0)) >= Grace {
			mark(w.id, w.run.PaneID)
		}
	}

	live := map[string]bool{} // the session id of every agent still running
	for _, s := range sessions {
		if state.Alive(s.PID) {
			live[s.ID] = true
		}
	}

	for _, s := range sessions {
		// A dead subagent is rule 1's business: acting on its record here
		// would let a state file left by a previous tmux server close a
		// window by pane id alone.
		if s.Parent == nil || !live[s.ID] {
			continue
		}
		if live[s.Parent.Session] {
			continue
		}
		if id, ok := byPane[s.Pane]; ok {
			// The child's own pane, which is the run's: its record is what
			// names it, so this rule needs no pane option to find it.
			mark(id, s.Pane) // rule 2
		}
	}
	return out, endings
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
func RecordEnding(meta subrun.Meta, o subrun.Outcome) (Ending, bool) {
	if err := subrun.RecordOutcome(meta.ID, o); err != nil {
		return Ending{}, false //nolint:nilerr // losing the write is the ordinary case, not a failure
	}
	if meta.ParentSession == "" {
		return Ending{}, false
	}
	var detail EndingDetail = AgentEnding{}
	if meta.Kind == subrun.KindBash {
		detail = BashEnding{}
	}
	return Ending{Meta: meta, Outcome: o, Detail: detail}, true
}

// recordEnding is RecordEnding for the run a sweep is about to collect:
// the sweep is the observer that has to guess what happened,
// and what it may guess depends on the kind. A bash run ended without
// its wrapper reporting; an agent run keeps the Died it always got, and
// the notice says only that nobody reported it.
func recordEnding(runID subrun.ID, now time.Time) (Ending, bool) {
	meta, err := subrun.ReadMeta(runID)
	if err != nil {
		// No meta is an agent-shaped run as far as every reader of it is
		// concerned, and one with nobody to tell.
		meta = subrun.Meta{ID: runID}
	}
	o := subrun.Outcome{Result: subrun.Died, At: now}
	if meta.Kind == subrun.KindBash {
		o = subrun.Outcome{Result: subrun.Failed, Text: "ended without its wrapper reporting", At: now}
	}
	return RecordEnding(meta, o)
}

// anyRunPane reports whether any pane carries tmux.RunOption, the
// precondition both rules share.
func anyRunPane(panes []tmux.Pane) bool {
	for _, p := range panes {
		if p.Run != "" {
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
			w = &window{id: p.WindowID}
			byID[p.WindowID] = w
			windows = append(windows, w)
		}
		w.paneIDs = append(w.paneIDs, p.PaneID)
		if p.Run != "" {
			w.run = p
		}
		if p.Watched() {
			w.focused = true // tmux.WindowFocused, for a window already folded
		}
	}
	return windows, byID, byPane
}
