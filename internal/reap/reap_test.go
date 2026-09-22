package reap

import (
	"fmt"
	"os"
	"os/exec"
	"slices"
	"strings"
	"testing"
	"time"

	"kido/internal/state"
	"kido/internal/subrun"
	"kido/internal/tmux"
)

var now = time.Unix(1700000000, 0)

// deadPID starts and waits for a trivial child process, returning its pid:
// guaranteed to belong to no process by the time the caller uses it. The
// same trick internal/state/state_test.go uses.
func deadPID(t *testing.T) int {
	t.Helper()
	cmd := exec.Command("true")
	if err := cmd.Run(); err != nil {
		t.Fatal(err)
	}
	return cmd.Process.Pid
}

// pane builds one pane of a one-pane window in session $0, which is what
// a spawned subagent's window is. The variations each test needs - the
// mark, death, whether anyone is watching - are set by the caller.
func pane(paneID, windowID string) tmux.Pane {
	return tmux.Pane{PaneID: paneID, WindowID: windowID, SessionID: "$0"}
}

// marked is p with the @kido_subagent option kido spawn sets.
func marked(p tmux.Pane) tmux.Pane {
	p.Subagent = "parent=root-inst depth=1"
	return p
}

// markedWithRun is marked, but with the "run=<id>" token a real kido
// spawn always includes and tmux.SubagentRunID actually parses. Spelled
// out rather than built with tmux.SubagentMark, so the parser is pinned
// against a literal mark: building the input with the producer would let
// both halves of the format drift together and still pass. The producer's
// own half is pinned the same way, by TestSpawnMarksTheWindow.
func markedWithRun(p tmux.Pane, runID string) tmux.Pane {
	p.Subagent = "run=" + runID + " parent=root-inst depth=1"
	return p
}

// dead is p as remain-on-exit leaves it: the command exited secs seconds
// before now.
func dead(p tmux.Pane, secs int) tmux.Pane {
	p.Dead, p.DeadTime = true, now.Add(-time.Duration(secs)*time.Second).Unix()
	return p
}

// watched is p as the pane a user is looking at.
func watched(p tmux.Pane) tmux.Pane {
	p.Active, p.SessionAttached = true, true
	return p
}

// other is a second window in the same session, so no test is deciding
// the last-window rule by accident.
var other = pane("%other", "@other")

func check(t *testing.T, got, want []string) {
	t.Helper()
	if !slices.Equal(got, want) {
		t.Errorf("Sweep = %v, want %v", got, want)
	}
}

// TestSweepClosesFinishedSubagentWindow is rule 1, and the whole point of
// the mark: no state record is involved at all, which is what lets it work
// in a session whose sidebar has already swept the record away.
func TestSweepClosesFinishedSubagentWindow(t *testing.T) {
	panes := []tmux.Pane{other, dead(marked(pane("%1", "@1")), 60)}
	check(t, Sweep(panes, nil, now), []string{"@1"})
}

// TestSweepWaitsOutTheGrace pins the read window: the linger exists so the
// user can see what a subagent did, and a sweep that closed the window the
// instant the pane died would take it away before the helper it backs up
// ever fires.
func TestSweepWaitsOutTheGrace(t *testing.T) {
	panes := []tmux.Pane{other, dead(marked(pane("%1", "@1")), 1)}
	check(t, Sweep(panes, nil, now), nil)
}

// TestSweepNeverTouchesAnUnmarkedWindow is the guard against the failure
// the mark was introduced for: a stale state file from a previous tmux
// server names %0, a pane id this server has since handed to somebody
// else's shell. Only a window kido spawn marked may ever be closed, so
// neither rule can reach it.
func TestSweepNeverTouchesAnUnmarkedWindow(t *testing.T) {
	stale := state.Session{Pane: "%1", PID: os.Getpid(),
		Instance: "child-inst", ParentInstance: "long-gone-inst"}
	panes := []tmux.Pane{other, dead(pane("%1", "@1"), 600)}
	check(t, Sweep(panes, []state.Session{stale}, now), nil)
}

// TestSweepNeverClosesASessionsLastWindow: closing it destroys the
// session itself, which is never what a sweep was asked to do.
func TestSweepNeverClosesASessionsLastWindow(t *testing.T) {
	panes := []tmux.Pane{dead(marked(pane("%1", "@1")), 600)}
	check(t, Sweep(panes, nil, now), nil)
}

// TestSweepCollectsAFocusedWindowOnceTheUserLeaves is what replaces the
// linger helper's retry loop. A window the user is reading is left alone,
// exactly as `kido close-window` leaves it - and because the sweep runs
// again on every poll, it is collected as soon as they switch away.
func TestSweepCollectsAFocusedWindowOnceTheUserLeaves(t *testing.T) {
	finished := dead(marked(pane("%1", "@1")), 600)
	check(t, Sweep([]tmux.Pane{other, watched(finished)}, nil, now), nil)
	check(t, Sweep([]tmux.Pane{watched(other), finished}, nil, now), []string{"@1"})
}

// TestSweepCancelsSubagentOfDeadParent is rule 2: the subagent is alive
// and its window is not dead, so only its parent's absence can close it.
// A single sweep is not enough - see TestSweepDoesNotActOnASingleMiss -
// so this drives its own isolated reaper across two sweeps OrphanGrace
// apart, the second of which finally closes the window.
func TestSweepCancelsSubagentOfDeadParent(t *testing.T) {
	child := state.Session{Pane: "%1", PID: os.Getpid(),
		Instance: "child-inst", ParentInstance: "root-inst"}
	// The parent record is still on disk (ReadAll keeps it) but its
	// process is gone, which is the reading that decides this.
	parent := state.Session{Pane: "%p", PID: deadPID(t), Instance: "root-inst"}
	panes := []tmux.Pane{other, marked(pane("%1", "@1"))}
	sessions := []state.Session{child, parent}

	r := newReaper()
	check(t, r.sweep(panes, sessions, now), nil)
	check(t, r.sweep(panes, sessions, now.Add(OrphanGrace)), []string{"@1"})
}

// TestSweepDoesNotActOnASingleMiss is the regression test for the real
// incident: a same-pane collision (state.beats) can evict the parent's
// own record for a tick or few, without its process ever dying, and
// having it reappear before OrphanGrace elapses must close nothing at
// all - not even after the clock would otherwise have run out, since
// seeing the parent again resets it.
func TestSweepDoesNotActOnASingleMiss(t *testing.T) {
	child := state.Session{Pane: "%1", PID: os.Getpid(),
		Instance: "child-inst", ParentInstance: "root-inst"}
	panes := []tmux.Pane{other, marked(pane("%1", "@1"))}
	missing := []state.Session{child} // the parent's own record is absent
	present := []state.Session{child, {Pane: "%p", PID: os.Getpid(), Instance: "root-inst"}}

	r := newReaper()
	check(t, r.sweep(panes, missing, now), nil)
	check(t, r.sweep(panes, present, now.Add(time.Second)), nil) // parent seen alive: clock reset
	check(t, r.sweep(panes, missing, now.Add(OrphanGrace)), nil) // not OrphanGrace since the reset
}

// TestSweepNeverActsOnAPaneCollisionAlone: the child remembers its
// parent's pid from when it was spawned (ParentPID), and that reading
// alone is enough to never even start the debounce clock, however many
// sweeps a collision (state.beats evicting the parent's own record for
// the pane) survives.
func TestSweepNeverActsOnAPaneCollisionAlone(t *testing.T) {
	child := state.Session{Pane: "%1", PID: os.Getpid(),
		Instance: "child-inst", ParentInstance: "root-inst", ParentPID: os.Getpid()}
	panes := []tmux.Pane{other, marked(pane("%1", "@1"))}
	// No session named "root-inst" at all: Load's beats() has evicted it
	// in favour of something else sharing the pane.
	sessions := []state.Session{child}

	r := newReaper()
	for i := 0; i < 5; i++ {
		check(t, r.sweep(panes, sessions, now.Add(time.Duration(i)*OrphanGrace)), nil)
	}
}

func TestSweepLeavesSubagentOfLiveParentAlone(t *testing.T) {
	child := state.Session{Pane: "%1", PID: os.Getpid(),
		Instance: "child-inst", ParentInstance: "root-inst"}
	parent := state.Session{Pane: "%p", PID: os.Getpid(), Instance: "root-inst"}
	panes := []tmux.Pane{other, marked(pane("%1", "@1"))}
	check(t, Sweep(panes, []state.Session{child, parent}, now), nil)
}

// TestSweepNeverTouchesARootAgent: a record with no ParentInstance is the
// user's own agent, not a subagent, and is nobody's to close - even with
// its window marked and its process gone, which is as close to reapable
// as a root record can look.
func TestSweepNeverTouchesARootAgent(t *testing.T) {
	root := state.Session{Pane: "%1", PID: deadPID(t), Instance: "root-inst"}
	panes := []tmux.Pane{other, marked(pane("%1", "@1"))}
	check(t, Sweep(panes, []state.Session{root}, now), nil)
}

// TestSweepWaitsForEverySplitPane: a subagent that split its own window
// and left something running in the other pane is still working.
func TestSweepWaitsForEverySplitPane(t *testing.T) {
	first := dead(marked(pane("%1", "@1")), 600)
	second := marked(pane("%2", "@1"))
	check(t, Sweep([]tmux.Pane{other, first, second}, nil, now), nil)

	second = dead(second, 600)
	check(t, Sweep([]tmux.Pane{other, first, second}, nil, now), []string{"@1"})
}

// TestSweepReturnsAWindowOnce: both rules can name the same window - a
// subagent that was killed along with its parent satisfies each - and it
// must still be closed once.
func TestSweepReturnsAWindowOnce(t *testing.T) {
	child := state.Session{Pane: "%1", PID: os.Getpid(),
		Instance: "child-inst", ParentInstance: "gone-inst"}
	panes := []tmux.Pane{other, dead(marked(pane("%1", "@1")), 600)}
	check(t, Sweep(panes, []state.Session{child}, now), []string{"@1"})
}

// TestSweepRecordsDiedForAWindowItCloses: a run whose window a sweep
// collects with no outcome already recorded is exactly the case Died
// exists for - the child never got a chance to say how it ended.
func TestSweepRecordsDiedForAWindowItCloses(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := subrun.Create("run-died", "x"); err != nil {
		t.Fatal(err)
	}
	panes := []tmux.Pane{other, dead(markedWithRun(pane("%1", "@1"), "run-died"), 60)}
	check(t, Sweep(panes, nil, now), []string{"@1"})

	got, ok, err := subrun.ReadOutcome("run-died")
	if err != nil || !ok {
		t.Fatalf("ReadOutcome = %+v, %v, %v", got, ok, err)
	}
	if got.Result != subrun.Died {
		t.Errorf("outcome = %q, want %q", got.Result, subrun.Died)
	}
}

// TestSweepDoesNotOverwriteARecordedOutcome: a run that already told its
// own story (Completed, say) must keep it even though the window a sweep
// finds afterwards looks identical to one that just died.
func TestSweepDoesNotOverwriteARecordedOutcome(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := subrun.Create("run-done", "x"); err != nil {
		t.Fatal(err)
	}
	if err := subrun.RecordOutcome("run-done", subrun.Outcome{Result: subrun.Completed, At: now}); err != nil {
		t.Fatal(err)
	}
	panes := []tmux.Pane{other, dead(markedWithRun(pane("%1", "@1"), "run-done"), 60)}
	check(t, Sweep(panes, nil, now), []string{"@1"})

	got, ok, err := subrun.ReadOutcome("run-done")
	if err != nil || !ok || got.Result != subrun.Completed {
		t.Errorf("outcome = %+v, %v, %v, want it to stay %q", got, ok, err, subrun.Completed)
	}
}

// stubCapture replaces capturePaneScreen for the duration of a test with
// one that returns text for a fixed pane id and an error for any other,
// and restores the real tmux.CaptureScreen afterwards.
func stubCapture(t *testing.T, paneID, text string) {
	t.Helper()
	real := capturePaneScreen
	capturePaneScreen = func(p string) (string, error) {
		if p != paneID {
			return "", fmt.Errorf("no such pane %q", p)
		}
		return text, nil
	}
	t.Cleanup(func() { capturePaneScreen = real })
}

// TestSweepCapturesScreenBeforeClosing: the whole point of capturing from
// inside Sweep rather than after it returns is that the caller only
// closes a window Sweep has already named, so a screen written here is
// always written before the window can be gone.
func TestSweepCapturesScreenBeforeClosing(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := subrun.Create("run-crash", "x"); err != nil {
		t.Fatal(err)
	}
	stubCapture(t, "%1", "panic: something went wrong\n")

	panes := []tmux.Pane{other, dead(markedWithRun(pane("%1", "@1"), "run-crash"), 60)}
	check(t, Sweep(panes, nil, now), []string{"@1"})

	got, ok, err := subrun.ReadScreen("run-crash")
	if err != nil || !ok {
		t.Fatalf("ReadScreen = %q, %v, %v", got, ok, err)
	}
	if got != "panic: something went wrong\n" {
		t.Errorf("screen = %q", got)
	}
}

// TestSweepCapturesNothingForAWindowItRefusesToClose covers both refusal
// reasons Sweep already has tests for above (focused, session's last
// window): neither may leave a screen behind, since neither closes the
// window a screen would be captured for.
func TestSweepCapturesNothingForAWindowItRefusesToClose(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := subrun.Create("run-focused", "x"); err != nil {
		t.Fatal(err)
	}
	stubCapture(t, "%1", "should never be written")

	finished := dead(markedWithRun(pane("%1", "@1"), "run-focused"), 600)
	check(t, Sweep([]tmux.Pane{other, watched(finished)}, nil, now), nil)

	if _, ok, err := subrun.ReadScreen("run-focused"); err != nil || ok {
		t.Fatalf("ReadScreen ok = %v, err = %v, want no screen for a window Sweep refused to close", ok, err)
	}

	if err := subrun.Create("run-lastwindow", "x"); err != nil {
		t.Fatal(err)
	}
	solo := []tmux.Pane{dead(markedWithRun(pane("%2", "@2"), "run-lastwindow"), 600)}
	check(t, Sweep(solo, nil, now), nil)
	if _, ok, err := subrun.ReadScreen("run-lastwindow"); err != nil || ok {
		t.Fatalf("ReadScreen ok = %v, err = %v, want no screen for a session's last window", ok, err)
	}
}

// TestSweepClosesEvenWhenCaptureFails: losing a screen is much better
// than leaking a window forever, so a capture-pane error must not stop
// the window from being closed.
func TestSweepClosesEvenWhenCaptureFails(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := subrun.Create("run-nopane", "x"); err != nil {
		t.Fatal(err)
	}
	stubCapture(t, "%never-matches", "unreachable")

	panes := []tmux.Pane{other, dead(markedWithRun(pane("%1", "@1"), "run-nopane"), 60)}
	check(t, Sweep(panes, nil, now), []string{"@1"})

	if _, ok, err := subrun.ReadScreen("run-nopane"); err != nil || ok {
		t.Fatalf("ReadScreen ok = %v, err = %v, want no screen after a failed capture", ok, err)
	}
}

// TestSweepBoundsTheCapturedScreen pins maxScreenBytes: a wedged agent's
// scrollback could be arbitrarily large, and what lands on disk must stay
// bounded regardless.
func TestSweepBoundsTheCapturedScreen(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := subrun.Create("run-huge", "x"); err != nil {
		t.Fatal(err)
	}
	huge := strings.Repeat("x", maxScreenBytes*2) + "TAIL"
	stubCapture(t, "%1", huge)

	panes := []tmux.Pane{other, dead(markedWithRun(pane("%1", "@1"), "run-huge"), 60)}
	check(t, Sweep(panes, nil, now), []string{"@1"})

	got, ok, err := subrun.ReadScreen("run-huge")
	if err != nil || !ok {
		t.Fatalf("ReadScreen = %q, %v, %v", got, ok, err)
	}
	if len(got) > maxScreenBytes {
		t.Errorf("len(screen) = %d, want <= %d", len(got), maxScreenBytes)
	}
	if !strings.HasSuffix(got, "TAIL") {
		t.Errorf("screen truncation dropped the tail: %q", got[max(0, len(got)-20):])
	}
}
