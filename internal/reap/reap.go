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
	"sync"
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

// OrphanGrace is how long rule 2 must see a subagent's parent continuously
// gone - in both the readings Sweep uses, see the rule below - before its
// window is actually closed. A parent's own state record can go missing
// for a tick or several without the parent having died: two records
// (typically a one-shot `pi --print` that inherited TMUX_PANE from its
// caller's pane) can briefly collide on one pane, and state.beats
// resolves that collision on each Load by timestamp, so the parent's own
// record can lose for as long as the intruder keeps reporting. A single
// miss is not evidence; closing a window kills the process inside it with
// no chance to run its own shutdown path. It must stay comfortably above
// pi's own parent-liveness poll (pi/kido-agents.ts, two consecutive
// misses at PARENT_LIVENESS_POLL_MS, ~10s by default) or the sweep races
// a child that was already shutting down cleanly on its own and stamps
// its outcome Died instead of whatever it was about to record itself.
var OrphanGrace = orphanGraceFromEnv(15 * time.Second)

func orphanGraceFromEnv(def time.Duration) time.Duration {
	if n, err := strconv.Atoi(os.Getenv("KIDO_ORPHAN_SECONDS")); err == nil && n > 0 {
		return time.Duration(n) * time.Second
	}
	return def
}

// reaper holds rule 2's debounce state across sweeps: firstMissed records,
// per parent instance, the first tick that instance looked gone by both
// of rule 2's readings. It is package-level state rather than a Sweep
// parameter because Sweep's signature is relied on by internal/ui and
// cmd/kido unchanged; a fresh process (`kido reap`) therefore starts with
// an empty map and can never fire rule 2 on its one and only sweep - rule
// 2 needs a long-running caller, the sidebar's poll, to see the same
// parent gone twice. `kido reap` still runs rule 1 in full.
type reaper struct {
	mu          sync.Mutex
	firstMissed map[string]time.Time // ParentInstance -> when it first looked gone
}

func newReaper() *reaper { return &reaper{firstMissed: map[string]time.Time{}} }

var defaultReaper = newReaper()

// window is what a sweep needs to know about one tmux window, folded out
// of the pane list.
type window struct {
	id       string
	paneIDs  []string // every pane in the window, in list-panes order
	marked   bool     // carries tmux.SubagentOption: a window kido spawn created
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

// Sweep returns the windows that should be closed now, in the order they
// appear in panes. sessions may come from state.Load or state.ReadAll;
// liveness is checked here rather than assumed, so both give the same
// answer.
//
// Two rules, both restricted to a window carrying tmux.SubagentOption:
//
//  1. every pane of a marked window is dead and has been for Grace. This
//     rule reads no state record at all.
//  2. a live subagent whose parent has looked gone, by both readings
//     Sweep has of it, for OrphanGrace is cancelled by closing its
//     window. A single miss - one Sweep call where the parent's record
//     is briefly unreadable - is not enough on its own; see OrphanGrace.
//     This debounce is per *process* (the package-level defaultReaper),
//     so only a caller that sweeps repeatedly, the sidebar's poll, can
//     ever trigger rule 2; a one-shot `kido reap` observes at most once
//     and so only ever applies rule 1.
//
// Neither rule closes a window that is any client's current one, or a
// session's last window.
func Sweep(panes []tmux.Pane, sessions []state.Session, now time.Time) []string {
	return defaultReaper.sweep(panes, sessions, now)
}

func (r *reaper) sweep(panes []tmux.Pane, sessions []state.Session, now time.Time) []string {
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
			captureScreen(w)
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

	r.mu.Lock()
	defer r.mu.Unlock()
	for _, s := range sessions {
		// A dead subagent is rule 1's business: acting on its record here
		// would let a state file left by a previous tmux server close a
		// window by pane id alone.
		if s.ParentInstance == "" || !state.Alive(s.PID) {
			continue
		}
		// Two independent readings of the parent's liveness: the registry's
		// per-pane record (live, built above) and the pid the child itself
		// recorded for its parent when it was spawned (ParentPID). A
		// same-pane collision can evict the parent's own record from
		// `sessions` for a few seconds without its pid ever dying, so
		// either reading saying "alive" is enough - and it is checked
		// before touching the debounce clock, so a transient collision
		// never even starts one. A record with no ParentPID (an older
		// report, or an agent that predates it) makes state.Alive(0) false
		// and falls straight through to the instance check alone, exactly
		// as before this change.
		if live[s.ParentInstance] || state.Alive(s.ParentPID) {
			delete(r.firstMissed, s.ParentInstance)
			continue
		}
		since, seen := r.firstMissed[s.ParentInstance]
		if !seen {
			r.firstMissed[s.ParentInstance] = now
			continue
		}
		if now.Sub(since) < OrphanGrace {
			continue
		}
		if id, ok := byPane[s.Pane]; ok {
			mark(id) // rule 2
		}
		delete(r.firstMissed, s.ParentInstance)
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
