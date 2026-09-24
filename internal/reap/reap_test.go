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

// marked is p with the @kido_subagent option kido spawn_subagent sets.
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

// runPane is p as the one pane a run actually runs in: the pane-scoped
// @kido_subagent_pane option createRunWindow sets, which is what tells
// the run's own pane from one the user split off later. The window
// option goes on too, since tmux's lookup would give every pane of the
// window that one anyway.
func runPane(p tmux.Pane, runID string) tmux.Pane {
	p = markedWithRun(p, runID)
	p.SubagentPane = runID
	return p
}

// split is a pane the user added to a run's window: it reads the window
// mark through tmux's option fallback and carries no pane option of its
// own.
func split(p tmux.Pane, runID string) tmux.Pane { return markedWithRun(p, runID) }

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

// sweep is Sweep's close list alone, for the tests whose subject is
// what a sweep closes. The notices are asserted on by name in the tests
// that are about them.
func sweep(panes []tmux.Pane, sessions []state.Session, now time.Time) []Close {
	closes, _ := Sweep(panes, sessions, now)
	return closes
}

// winClose and paneClose are the two things a sweep can ask for: the
// whole window, or the run's own pane with the rest of the window left
// standing.
func winClose(id string) Close         { return Close{WindowID: id} }
func paneClose(win, pane string) Close { return Close{WindowID: win, PaneID: pane} }

func check(t *testing.T, got []Close, want ...Close) {
	t.Helper()
	if !slices.Equal(got, want) {
		t.Errorf("Sweep = %+v, want %+v", got, want)
	}
}

// TestSweepClosesFinishedSubagentWindow is rule 1, and the whole point of
// the mark: no state record is involved at all, which is what lets it work
// in a session whose sidebar has already swept the record away.
func TestSweepClosesFinishedSubagentWindow(t *testing.T) {
	panes := []tmux.Pane{other, dead(marked(pane("%1", "@1")), 60)}
	check(t, sweep(panes, nil, now), winClose("@1"))
}

// TestSweepWaitsOutTheGrace pins the read window: the linger exists so the
// user can see what a subagent did, and a sweep that closed the window the
// instant the pane died would take it away before the helper it backs up
// ever fires.
func TestSweepWaitsOutTheGrace(t *testing.T) {
	panes := []tmux.Pane{other, dead(marked(pane("%1", "@1")), 1)}
	check(t, sweep(panes, nil, now))
}

// TestSweepNeverTouchesAnUnmarkedWindow is the guard against the failure
// the mark was introduced for: a stale state file from a previous tmux
// server names %0, a pane id this server has since handed to somebody
// else's shell. Only a window kido spawn_subagent marked may ever be closed, so
// neither rule can reach it - and with no mark anywhere in the pane
// list, Sweep says so without folding the windows at all.
func TestSweepNeverTouchesAnUnmarkedWindow(t *testing.T) {
	stale := state.Session{Pane: "%1", PID: os.Getpid(),
		Instance: "child-inst", ParentInstance: "long-gone-inst"}
	panes := []tmux.Pane{other, dead(pane("%1", "@1"), 600)}
	check(t, sweep(panes, []state.Session{stale}, now))
}

// TestSweepNeverClosesASessionsLastWindow: closing it destroys the
// session itself, which is never what a sweep was asked to do.
func TestSweepNeverClosesASessionsLastWindow(t *testing.T) {
	panes := []tmux.Pane{dead(marked(pane("%1", "@1")), 600)}
	check(t, sweep(panes, nil, now))
}

// TestSweepCollectsAFocusedWindowOnceTheUserLeaves is what replaces the
// linger helper's retry loop. A window the user is reading is left alone,
// exactly as `kido close-window` leaves it - and because the sweep runs
// again on every poll, it is collected as soon as they switch away.
func TestSweepCollectsAFocusedWindowOnceTheUserLeaves(t *testing.T) {
	finished := dead(marked(pane("%1", "@1")), 600)
	check(t, sweep([]tmux.Pane{other, watched(finished)}, nil, now))
	check(t, sweep([]tmux.Pane{watched(other), finished}, nil, now), winClose("@1"))
}

// TestSweepCancelsSubagentOfDeadParent is rule 2: the subagent is alive
// and its window is not dead, so only its parent's absence can close it.
// One reading of the complete set decides it, which is what lets a
// one-shot `kido reap` apply this rule at all.
func TestSweepCancelsSubagentOfDeadParent(t *testing.T) {
	child := state.Session{Pane: "%1", PID: os.Getpid(),
		Instance: "child-inst", ParentInstance: "root-inst"}
	// The parent record is still on disk (ReadAll keeps it) but its
	// process is gone, which is the reading that decides this.
	parent := state.Session{Pane: "%p", PID: deadPID(t), Instance: "root-inst"}
	panes := []tmux.Pane{other, marked(pane("%1", "@1"))}
	check(t, sweep(panes, []state.Session{child, parent}, now), winClose("@1"))
}

// TestSweepSurvivesAPaneCollisionOnTheParent is the regression test for
// the real incident, written against what now prevents it rather than
// against what used to absorb it. A second live agent claiming the
// parent's own pane - a `pi --print` that inherited TMUX_PANE - takes
// that pane away from the parent in state.Load's per-pane view, and the
// parent's own record is then simply not in what the sweep is handed.
// No liveness check can recover a record the caller dropped, so the
// sweep has to be given the whole set (state.LoadLive), and with it the
// parent is plainly alive for as long as the collision lasts.
//
// The records go through real state files so the two packages' contract
// is what is under test, not a hand-built slice agreeing with itself.
// The per-pane view is swept too, as a negative control: it is the input
// that killed two live agents, and if it stopped closing the window this
// test would no longer be about anything.
//
// The window carries a bash run, so what a lossy reading costs is
// counted in full: it does not merely close a live window, it records an
// ending for a command that is still running and tells the parent a
// story that is false. The notices are asserted on in both halves for
// that reason - silence from the complete reading, exactly one from the
// lossy one - since a sweep is now something that speaks and not only
// something that closes.
func TestSweepSurvivesAPaneCollisionOnTheParent(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	bashRun(t, "run-collision", "build", "root-inst")
	live := time.Now()
	record(t, "parent", state.Session{Pane: "%p", PID: os.Getpid(),
		Agent: state.AgentPi, Instance: "root-inst", TS: live})
	record(t, "child", state.Session{Pane: "%1", PID: os.Getpid(),
		Agent: state.AgentPi, Instance: "child-inst", ParentInstance: "root-inst", TS: live})
	record(t, "intruder", state.Session{Pane: "%p", PID: os.Getpid(),
		Agent: state.AgentPi, Instance: "intruder-inst", TS: live.Add(time.Second)})
	panes := []tmux.Pane{other, markedWithRun(pane("%1", "@1"), "run-collision")}

	all, err := state.LoadLive()
	if err != nil {
		t.Fatal(err)
	}
	closing, told := Sweep(panes, all, now)
	check(t, closing)
	if len(told) != 0 {
		t.Errorf("a complete reading produced %+v, want silence: the run is still going", told)
	}
	if o, ok, _ := subrun.ReadOutcome("run-collision"); ok {
		t.Errorf("a complete reading recorded %+v for a run that is still going", o)
	}

	byPane, err := state.Load()
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := byPane["%p"]; !ok || byPane["%p"].Instance != "intruder-inst" {
		t.Fatalf("state.Load has %+v on the parent's pane, want the intruder to have won it", byPane["%p"])
	}
	lossy := make([]state.Session, 0, len(byPane))
	for _, s := range byPane {
		lossy = append(lossy, s)
	}
	closing, told = Sweep(panes, lossy, now)
	check(t, closing, winClose("@1"))
	if len(told) != 1 {
		t.Errorf("the lossy reading produced %d notices, want the 1 that shows what it costs", len(told))
	}
}

// record writes one state file, so a test can exercise the same read
// path the sidebar uses.
func record(t *testing.T, id string, s state.Session) {
	t.Helper()
	if err := state.Record(id, s); err != nil {
		t.Fatal(err)
	}
}

func TestSweepLeavesSubagentOfLiveParentAlone(t *testing.T) {
	child := state.Session{Pane: "%1", PID: os.Getpid(),
		Instance: "child-inst", ParentInstance: "root-inst"}
	parent := state.Session{Pane: "%p", PID: os.Getpid(), Instance: "root-inst"}
	panes := []tmux.Pane{other, marked(pane("%1", "@1"))}
	check(t, sweep(panes, []state.Session{child, parent}, now))
}

// TestSweepNeverTouchesARootAgent: a record with no ParentInstance is the
// user's own agent, not a subagent, and is nobody's to close - even with
// its window marked and its process gone, which is as close to reapable
// as a root record can look.
func TestSweepNeverTouchesARootAgent(t *testing.T) {
	root := state.Session{Pane: "%1", PID: deadPID(t), Instance: "root-inst"}
	panes := []tmux.Pane{other, marked(pane("%1", "@1"))}
	check(t, sweep(panes, []state.Session{root}, now))
}

// TestSweepWaitsForEverySplitPane: a subagent that split its own window
// and left something running in the other pane is still working.
func TestSweepWaitsForEverySplitPane(t *testing.T) {
	first := dead(marked(pane("%1", "@1")), 600)
	second := marked(pane("%2", "@1"))
	check(t, sweep([]tmux.Pane{other, first, second}, nil, now))

	second = dead(second, 600)
	check(t, sweep([]tmux.Pane{other, first, second}, nil, now), winClose("@1"))
}

// TestSweepReturnsAWindowOnce: both rules can name the same window - a
// subagent that was killed along with its parent satisfies each - and it
// must still be closed once.
func TestSweepReturnsAWindowOnce(t *testing.T) {
	child := state.Session{Pane: "%1", PID: os.Getpid(),
		Instance: "child-inst", ParentInstance: "gone-inst"}
	panes := []tmux.Pane{other, dead(marked(pane("%1", "@1")), 600)}
	check(t, sweep(panes, []state.Session{child}, now), winClose("@1"))
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
	check(t, sweep(panes, nil, now), winClose("@1"))

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
	check(t, sweep(panes, nil, now), winClose("@1"))

	got, ok, err := subrun.ReadOutcome("run-done")
	if err != nil || !ok || got.Result != subrun.Completed {
		t.Errorf("outcome = %+v, %v, %v, want it to stay %q", got, ok, err, subrun.Completed)
	}
}

// stubCapture replaces subrun.CapturePane for the duration of a test with
// one that returns text for a fixed pane id and an error for any other,
// and restores the real tmux.CaptureScreen afterwards.
func stubCapture(t *testing.T, paneID, text string) {
	t.Helper()
	real := subrun.CapturePane
	subrun.CapturePane = func(p string) (string, error) {
		if p != paneID {
			return "", fmt.Errorf("no such pane %q", p)
		}
		return text, nil
	}
	t.Cleanup(func() { subrun.CapturePane = real })
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
	check(t, sweep(panes, nil, now), winClose("@1"))

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
	check(t, sweep([]tmux.Pane{other, watched(finished)}, nil, now))

	if _, ok, err := subrun.ReadScreen("run-focused"); err != nil || ok {
		t.Fatalf("ReadScreen ok = %v, err = %v, want no screen for a window Sweep refused to close", ok, err)
	}

	if err := subrun.Create("run-lastwindow", "x"); err != nil {
		t.Fatal(err)
	}
	solo := []tmux.Pane{dead(markedWithRun(pane("%2", "@2"), "run-lastwindow"), 600)}
	check(t, sweep(solo, nil, now))
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
	check(t, sweep(panes, nil, now), winClose("@1"))

	if _, ok, err := subrun.ReadScreen("run-nopane"); err != nil || ok {
		t.Fatalf("ReadScreen ok = %v, err = %v, want no screen after a failed capture", ok, err)
	}
}

// TestSweepBoundsTheCapturedScreen pins subrun.MaxScreenBytes: a wedged
// agent's scrollback could be arbitrarily large, and what lands on disk
// must stay bounded regardless.
func TestSweepBoundsTheCapturedScreen(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := subrun.Create("run-huge", "x"); err != nil {
		t.Fatal(err)
	}
	huge := strings.Repeat("x", subrun.MaxScreenBytes*2) + "TAIL"
	stubCapture(t, "%1", huge)

	panes := []tmux.Pane{other, dead(markedWithRun(pane("%1", "@1"), "run-huge"), 60)}
	check(t, sweep(panes, nil, now), winClose("@1"))

	got, ok, err := subrun.ReadScreen("run-huge")
	if err != nil || !ok {
		t.Fatalf("ReadScreen = %q, %v, %v", got, ok, err)
	}
	if len(got) > subrun.MaxScreenBytes {
		t.Errorf("len(screen) = %d, want <= %d", len(got), subrun.MaxScreenBytes)
	}
	if !strings.HasSuffix(got, "TAIL") {
		t.Errorf("screen truncation dropped the tail: %q", got[max(0, len(got)-20):])
	}
}

// bashRun writes the meta a `kido async_bash` window's run has: kind
// bash, and a parent to tell. parent may be empty, which is a run
// started from a shell nobody was tracking.
func bashRun(t *testing.T, id, name, parent string) {
	t.Helper()
	if err := subrun.Create(id, "make -j8"); err != nil {
		t.Fatal(err)
	}
	if err := subrun.WriteMeta(subrun.Meta{ID: id, Name: name, Kind: subrun.KindBash,
		ParentInstance: parent}); err != nil {
		t.Fatal(err)
	}
}

// notices is Sweep's second return, for the tests that are about it.
func notices(t *testing.T, panes []tmux.Pane, sessions []state.Session) []Notice {
	t.Helper()
	_, out := Sweep(panes, sessions, now)
	return out
}

// TestSweepNotifiesForABashRunNobodyReported is rule 1 as the backstop
// that makes "never zero" true. The wrapper records and notifies before
// it exits, so it covers every ending it lives to see; an ending it does
// not - SIGKILL, a window closed by hand, the process tree gone - leaves
// a marked window with dead panes and no outcome, which is precisely
// what this sweep finds. Before this, it recorded died and said nothing,
// and a parent waited forever on a build that had already stopped
// existing.
func TestSweepNotifiesForABashRunNobodyReported(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	bashRun(t, "run-killed", "build", "root-inst")
	panes := []tmux.Pane{other, dead(markedWithRun(pane("%1", "@1"), "run-killed"), 60)}

	got := notices(t, panes, nil)
	if len(got) != 1 {
		t.Fatalf("Sweep returned %d notices, want exactly 1: %+v", len(got), got)
	}
	if got[0].Meta.Name != "build" || got[0].Meta.ParentInstance != "root-inst" {
		t.Errorf("notice names %+v, want the run's own name and parent", got[0].Meta)
	}
	if got[0].Outcome.Result != subrun.Failed || got[0].Outcome.Text != sweptText {
		t.Errorf("notice carries %+v, want %q/%q", got[0].Outcome, subrun.Failed, sweptText)
	}
	o, ok, err := subrun.ReadOutcome("run-killed")
	if err != nil || !ok || o.Result != subrun.Failed || o.Text != sweptText {
		t.Errorf("ReadOutcome = %+v, %v, %v, want the same story on disk", o, ok, err)
	}
}

// TestSweepSaysNothingForABashRunItsWrapperReported is the negative
// control the test above is unsafe without, and the half that carries
// the invariant: exactly one notice per run, never two. A wrapper that
// already recorded the ending has already sent its own notice with its
// own exit status and its own output tail, and the sweep that comes
// along afterwards finds a window indistinguishable from one whose
// wrapper never spoke. Only the outcome on disk tells them apart, and it
// is the O_EXCL write - not a flag, not a marker file - that must be
// what is read.
//
// Without this half, a sweep that notified unconditionally would pass
// every assertion in the positive test.
func TestSweepSaysNothingForABashRunItsWrapperReported(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	bashRun(t, "run-told", "build", "root-inst")
	if err := subrun.RecordOutcome("run-told", subrun.Outcome{
		Result: subrun.Failed, Text: "exit status 3", At: now}); err != nil {
		t.Fatal(err)
	}
	panes := []tmux.Pane{other, dead(markedWithRun(pane("%1", "@1"), "run-told"), 60)}

	closing, got := Sweep(panes, nil, now)
	check(t, closing, winClose("@1"))
	if len(got) != 0 {
		t.Errorf("Sweep returned %+v, want nothing: the wrapper already reported this ending", got)
	}
	if o, _, _ := subrun.ReadOutcome("run-told"); o.Text != "exit status 3" {
		t.Errorf("outcome = %+v, want the wrapper's own story to stand", o)
	}
}

// TestSweepNotifiesOnceUnderTwoObservers: a sidebar per client, plus
// whatever `kido reap` an operator types, all sweep the same window, and
// a window a sweep names is not closed until its caller gets round to
// it. The second sweep sees exactly what the first saw and must still
// produce no notice - which is the outcome write arbitrating, since
// nothing else about the two readings differs.
func TestSweepNotifiesOnceUnderTwoObservers(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	bashRun(t, "run-raced", "build", "root-inst")
	panes := []tmux.Pane{other, dead(markedWithRun(pane("%1", "@1"), "run-raced"), 60)}

	total := len(notices(t, panes, nil)) + len(notices(t, panes, nil))
	if total != 1 {
		t.Errorf("two sweeps of one ending produced %d notices, want exactly 1", total)
	}
}

// agentRun writes the meta a `kido spawn_subagent` window's run has: no
// kind at all, which every reader takes as an agent run, and a parent to
// tell.
func agentRun(t *testing.T, id, name, parent string) {
	t.Helper()
	if err := subrun.Create(id, "do a thing"); err != nil {
		t.Fatal(err)
	}
	if err := subrun.WriteMeta(subrun.Meta{ID: id, Name: name, ParentInstance: parent}); err != nil {
		t.Fatal(err)
	}
}

// TestSweepNotifiesForAnAgentRunNobodyReported: a child's window found
// gone or dead with no outcome recorded is a child that never reported,
// and its parent is told so. This inverts what the sweep used to do -
// record died and say nothing - which left a parent that had dispatched
// work waiting on a child that no longer existed. The notice is not a
// verdict on the work: it says only that the run ended and nothing was
// said about it, which is the one thing a window sweep can know.
func TestSweepNotifiesForAnAgentRunNobodyReported(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	agentRun(t, "run-agent", "kid", "root-inst")
	panes := []tmux.Pane{other, dead(markedWithRun(pane("%1", "@1"), "run-agent"), 60)}

	closing, got := Sweep(panes, nil, now)
	check(t, closing, winClose("@1"))
	if len(got) != 1 {
		t.Fatalf("Sweep returned %d notices for an unreported agent run, want exactly 1: %+v", len(got), got)
	}
	if got[0].Meta.Name != "kid" || got[0].Meta.ParentInstance != "root-inst" {
		t.Errorf("notice names %+v, want the run's own name and parent", got[0].Meta)
	}
	if got[0].Outcome.Result != subrun.Died {
		t.Errorf("notice carries %+v, want the %q an agent run has always been recorded with", got[0].Outcome, subrun.Died)
	}
	if o, _, _ := subrun.ReadOutcome("run-agent"); o.Result != subrun.Died {
		t.Errorf("agent run's outcome = %q, want it to stay %q", o.Result, subrun.Died)
	}
}

// TestSweepSaysNothingForAnAgentRunThatReported is the negative control
// the test above is unsafe without, and it is the same one a bash run
// has: a child that reported recorded its own outcome on the way out,
// and the window the sweep then finds is indistinguishable from the one
// above. Only the O_EXCL outcome write tells them apart, so a sweep that
// notified unconditionally would pass every assertion in the positive
// half and tell the parent about one ending twice.
func TestSweepSaysNothingForAnAgentRunThatReported(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	agentRun(t, "run-said", "kid", "root-inst")
	if err := subrun.RecordOutcome("run-said", subrun.Outcome{Result: subrun.Completed, At: now}); err != nil {
		t.Fatal(err)
	}
	panes := []tmux.Pane{other, dead(markedWithRun(pane("%1", "@1"), "run-said"), 60)}

	closing, got := Sweep(panes, nil, now)
	check(t, closing, winClose("@1"))
	if len(got) != 0 {
		t.Errorf("Sweep returned %+v, want nothing: this run's own child already spoke for it", got)
	}
	if o, _, _ := subrun.ReadOutcome("run-said"); o.Result != subrun.Completed {
		t.Errorf("outcome = %+v, want the child's own story to stand", o)
	}
}

// TestSweepNotifiesNobodyForAParentlessBashRun: `kido async_bash` typed
// at a human's shell records no parent instance, and a notice with
// nobody to receive it is not a notice. The ending is still recorded,
// which is the half that matters to `kido runs`.
func TestSweepNotifiesNobodyForAParentlessBashRun(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	bashRun(t, "run-loner", "build", "")
	panes := []tmux.Pane{other, dead(markedWithRun(pane("%1", "@1"), "run-loner"), 60)}

	if got := notices(t, panes, nil); len(got) != 0 {
		t.Errorf("Sweep returned %+v, want nothing: this run has no parent to tell", got)
	}
	if o, ok, _ := subrun.ReadOutcome("run-loner"); !ok || o.Result != subrun.Failed {
		t.Errorf("outcome = %+v (recorded %v), want the ending recorded regardless", o, ok)
	}
}

// TestSweepClosesTheRunsPaneAndLeavesTheSplit is the rule the collection
// unit changed to: the user split a shell into a subagent's window, the
// run finished, and what is finished with is the run's dead pane - not
// the window, which now holds a live shell of the user's own. The whole
// window was the unit before this, so the dead pane sat beside their
// shell until they left the window.
func TestSweepClosesTheRunsPaneAndLeavesTheSplit(t *testing.T) {
	run := dead(runPane(pane("%1", "@1"), "run-split"), 600)
	shell := split(pane("%2", "@1"), "run-split")
	check(t, sweep([]tmux.Pane{other, run, shell}, nil, now), paneClose("@1", "%1"))
}

// TestSweepClosesTheWindowWhenTheRunsPaneIsAllOfIt is the negative
// control for the test above, and the case every other test here is:
// with nothing beside it, the run's pane is the window, and killing the
// pane and closing the window are the same act - but only the window
// close is held to the last-window refusal, so they must not be spelled
// the same.
func TestSweepClosesTheWindowWhenTheRunsPaneIsAllOfIt(t *testing.T) {
	run := dead(runPane(pane("%1", "@1"), "run-solo"), 600)
	check(t, sweep([]tmux.Pane{other, run}, nil, now), winClose("@1"))
}

// TestSweepStillWaitsForTheGraceOnARunsPane: the read window the linger
// gives the user is the pane's, measured from that pane's own death, and
// not the window's.
func TestSweepStillWaitsForTheGraceOnARunsPane(t *testing.T) {
	run := dead(runPane(pane("%1", "@1"), "run-young"), 1)
	shell := split(pane("%2", "@1"), "run-young")
	check(t, sweep([]tmux.Pane{other, run, shell}, nil, now))
}

// TestSweepLeavesALiveRunsPaneAlone: a run still going is not collected
// because something else in its window died.
func TestSweepLeavesALiveRunsPaneAlone(t *testing.T) {
	run := runPane(pane("%1", "@1"), "run-going")
	corpse := dead(split(pane("%2", "@1"), "run-going"), 600)
	check(t, sweep([]tmux.Pane{other, run, corpse}, nil, now))
}

// TestSweepRefusesTheRunsPaneInAFocusedWindow keeps the focus rule as
// one rule for both units: the user switched to this window to read what
// the run left on screen, and a pane killed under them takes that screen
// away and resizes what is left. Collected as soon as they move on,
// which is the second half here.
func TestSweepRefusesTheRunsPaneInAFocusedWindow(t *testing.T) {
	run := dead(runPane(pane("%1", "@1"), "run-read"), 600)
	shell := watched(split(pane("%2", "@1"), "run-read"))
	check(t, sweep([]tmux.Pane{other, run, shell}, nil, now))

	shell.Active, shell.SessionAttached = false, true
	check(t, sweep([]tmux.Pane{watched(other), run, shell}, nil, now), paneClose("@1", "%1"))
}

// TestSweepClosesARunsPaneInASessionsLastWindow: the last-window refusal
// is about destroying a session, and killing one pane of a window that
// has another does no such thing. This is the split-window case of the
// refusal TestSweepNeverClosesASessionsLastWindow pins.
func TestSweepClosesARunsPaneInASessionsLastWindow(t *testing.T) {
	run := dead(runPane(pane("%1", "@1"), "run-last"), 600)
	shell := split(pane("%2", "@1"), "run-last")
	check(t, sweep([]tmux.Pane{run, shell}, nil, now), paneClose("@1", "%1"))
}

// TestSweepCapturesOnlyTheRunsPane: the screen kept for a run is the
// run's own, and a split holding the user's shell is no part of it.
func TestSweepCapturesOnlyTheRunsPane(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := subrun.Create("run-screen", "x"); err != nil {
		t.Fatal(err)
	}
	stubCapture(t, "%1", "the run's last screen\n")

	run := dead(runPane(pane("%1", "@1"), "run-screen"), 600)
	shell := split(pane("%2", "@1"), "run-screen")
	check(t, sweep([]tmux.Pane{other, run, shell}, nil, now), paneClose("@1", "%1"))

	got, ok, err := subrun.ReadScreen("run-screen")
	if err != nil || !ok {
		t.Fatalf("ReadScreen = %q, %v, %v", got, ok, err)
	}
	if got != "the run's last screen\n" {
		t.Errorf("screen = %q, want the run's pane alone and no pane-labelled blocks", got)
	}
}

// TestSweepNotifiesOnceForARunsPane: the exactly-once invariant does not
// care which unit is collected. The outcome write is still the arbiter,
// so a second observer of the same split window says nothing.
func TestSweepNotifiesOnceForARunsPane(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	bashRun(t, "run-paned", "build", "root-inst")
	run := dead(runPane(pane("%1", "@1"), "run-paned"), 600)
	shell := split(pane("%2", "@1"), "run-paned")
	panes := []tmux.Pane{other, run, shell}

	total := len(notices(t, panes, nil)) + len(notices(t, panes, nil))
	if total != 1 {
		t.Errorf("two sweeps of one ending produced %d notices, want exactly 1", total)
	}
	if o, ok, _ := subrun.ReadOutcome("run-paned"); !ok || o.Result != subrun.Failed {
		t.Errorf("outcome = %+v (recorded %v), want the ending recorded before the pane is killed", o, ok)
	}
}

// TestSweepCancelsAnOrphanByItsOwnPane is rule 2 under the same unit: a
// live child whose parent is gone is cancelled by killing the pane it
// runs in, and a bystander pane the user split into its window is no
// part of the cancellation.
func TestSweepCancelsAnOrphanByItsOwnPane(t *testing.T) {
	child := state.Session{Pane: "%1", PID: os.Getpid(),
		Instance: "child-inst", ParentInstance: "root-inst"}
	parent := state.Session{Pane: "%p", PID: deadPID(t), Instance: "root-inst"}
	panes := []tmux.Pane{other, runPane(pane("%1", "@1"), "run-orphan"), split(pane("%2", "@1"), "run-orphan")}
	check(t, sweep(panes, []state.Session{child, parent}, now), paneClose("@1", "%1"))
}
