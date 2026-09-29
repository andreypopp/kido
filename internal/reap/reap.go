// Package reap decides which subagent panes are finished with, run from
// the sidebar's poll, `kido reap`, and the linger helper `kido
// close-run`. What a sweep may close is decided from tmux's @kido_run
// option, never from a state record.
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
	paneIDs []string  // every pane in the window, in list-panes order
	run     tmux.Pane // the pane carrying tmux.RunOption, or the zero Pane
	focused bool
}

// Close is one thing a sweep wants closed. PaneID is "" when the whole
// window is to be closed.
type Close struct {
	WindowID string
	PaneID   string
}

// Ops are the tmux acts a Close is carried out with, indirected for
// tests.
type Ops struct {
	KillWindow func(string) error
	KillPane   func(string) error
}

// Release carries out c: close the window when the run was all of it, or
// kill the run's own pane and hand the window back to whatever the user
// left in it. RunOption is pane-scoped, so killing the run's pane clears
// it with no separate unmark step.
func (o Ops) Release(c Close) error {
	if c.PaneID == "" {
		return o.KillWindow(c.WindowID)
	}
	return o.KillPane(c.PaneID)
}

// Decide is `kido close-run`'s decision for windowID: the Close to
// release, or a refusal explaining why nothing was done.
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
	if tmux.LastWindow(panes, windowID) {
		return Close{}, fmt.Sprintf("%s is its session's only window; closing it would destroy the session", windowID)
	}
	return Close{WindowID: windowID}, ""
}

// Collect is one full sweep: what Sweep finds, released, then the
// endings this caller won and must now tell the parent about.
func Collect(panes []tmux.Pane, sessions []state.Session, now time.Time, ops Ops) {
	closing, endings := Sweep(panes, sessions, now)
	for _, c := range closing {
		ops.Release(c) //nolint:errcheck // best effort: another sweep or close-run may have won the race
	}
	for _, e := range endings {
		e.Send() //nolint:errcheck // best effort; the outcome is already recorded
	}
}

// captureScreen saves the final screen of paneIDs into runID's directory
// before the caller closes anything. A capture-pane error or a
// WriteScreen race lost to another sweep is silently skipped: either way
// the pane is still closed.
func captureScreen(runID subrun.ID, paneIDs []string) {
	var b strings.Builder
	for _, paneID := range paneIDs {
		text, err := subrun.CapturePane(paneID)
		if err != nil {
			continue
		}
		if len(paneIDs) > 1 {
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
// itself. Detail is a BashEnding iff Meta.Kind == subrun.KindBash.
type Ending struct {
	Meta    subrun.Meta
	Outcome subrun.Outcome
	Detail  EndingDetail
}

// EndingDetail is what an Ending's Send says beyond the shared outcome:
// a bash run's output, or an agent run's own record of whether it spoke
// for itself.
type EndingDetail interface{ body(Ending) string }

// BashEnding is a `kido async_bash` run's own half of an ending notice.
// Unstreamed is how many output lines never reached the parent while it
// ran (--stream only).
type BashEnding struct{ Unstreamed int }

// AgentEnding is a `kido spawn_subagent` run's own half of an ending
// notice. Unreported is the child's own word that it never called
// notify_parent (`kido run-outcome --unreported`).
type AgentEnding struct{ Unreported bool }

// label names a run wherever an Ending speaks of it. A run nobody named
// is its own id.
func (e Ending) label() string {
	if e.Meta.Name == "" {
		return string(e.Meta.ID)
	}
	return e.Meta.Name
}

// Send delivers e to the run's parent, as a notice envelope over its
// inbox. A run nobody started (e.g. an async_bash typed at a human's
// shell) has no parent session and is skipped.
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
// record as a reported one.
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
// UTF-8 rune and anything still invalid is replaced: a notice must be
// valid UTF-8, and a build log can end mid-character.
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
// sessions must be every live record (state.LoadLive or state.ReadAll),
// never a per-pane view (state.Load): rule 2 needs the complete set, or
// it can read a parent whose pane a second process transiently claimed
// (state.beats) as dead and close a healthy child's window.
//
// Two rules, both restricted to a window carrying a run pane
// (tmux.RunOption):
//
//  1. the run's own pane is dead and has been for Grace.
//  2. a live subagent no live record claims as a parent is orphaned, and
//     is cancelled by closing the pane it runs in.
//
// Neither rule touches a window that is any client's current one, and
// neither closes a session's last window.
func Sweep(panes []tmux.Pane, sessions []state.Session, now time.Time) ([]Close, []Ending) {
	if !anyRunPane(panes) {
		return nil, nil
	}
	windows, byID, byPane := foldWindows(panes)

	closing := map[string]bool{}
	var out []Close
	var endings []Ending
	// A pane that is all its window has is promoted to a window close, so
	// the last-window refusal below applies to it.
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
		if w.run.PaneID == "" {
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
		if s.Parent == nil || !live[s.ID] {
			continue
		}
		if live[s.Parent.Session] {
			continue
		}
		if id, ok := byPane[s.Pane]; ok {
			mark(id, s.Pane) // rule 2
		}
	}
	return out, endings
}

// RecordEnding writes o as the ending of meta's run and reports the
// notice the run's parent is owed, if this writer is the one that has to
// send it. The outcome write is O_EXCL, so exactly one observer of any
// ending ever speaks.
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

// recordEnding is RecordEnding for the run a sweep is about to collect,
// guessing what happened from the run's kind: a bash run ended without
// its wrapper reporting; an agent run is recorded Died.
func recordEnding(runID subrun.ID, now time.Time) (Ending, bool) {
	meta, err := subrun.ReadMeta(runID)
	if err != nil {
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
