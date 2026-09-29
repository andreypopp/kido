package reap

import (
	"fmt"
	"os"
	"slices"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"kido/internal/state"
	"kido/internal/subrun"
	"kido/internal/testutil"
	"kido/internal/tmux"
)

var now = time.Unix(1700000000, 0)

// pane builds one pane of a one-pane window in session $0.
func pane(paneID, windowID string) tmux.Pane {
	return tmux.Pane{PaneID: paneID, WindowID: windowID, SessionID: "$0"}
}

// runPane is p marked with @kido_run (tmux.RunOption) set to runID.
func runPane(p tmux.Pane, runID string) tmux.Pane {
	p.Run = runID
	return p
}

// dead is p as remain-on-exit leaves it: the command exited secs seconds
// before now.
func dead(p tmux.Pane, secs int) tmux.Pane {
	p.DeadAt = now.Add(-time.Duration(secs) * time.Second).Unix()
	return p
}

// watched is p as the pane a user is looking at.
func watched(p tmux.Pane) tmux.Pane {
	p.Active, p.SessionAttached = true, true
	return p
}

// other is a second window in the same session, so no test triggers the
// last-window rule by accident.
var other = pane("%other", "@other")

// sweep is Sweep's close list alone.
func sweep(panes []tmux.Pane, sessions []state.Session, now time.Time) []Close {
	closes, _ := Sweep(panes, sessions, now)
	return closes
}

func winClose(id string) Close         { return Close{WindowID: id} }
func paneClose(win, pane string) Close { return Close{WindowID: win, PaneID: pane} }

func check(t *testing.T, got []Close, want ...Close) {
	t.Helper()
	if !slices.Equal(got, want) {
		t.Errorf("Sweep = %+v, want %+v", got, want)
	}
}

// TestSweepClosesFinishedSubagentWindow is rule 1: no state record is
// involved at all.
func TestSweepClosesFinishedSubagentWindow(t *testing.T) {
	panes := []tmux.Pane{other, dead(runPane(pane("%1", "@1"), "run-finished"), 60)}
	check(t, sweep(panes, nil, now), winClose("@1"))
}

// TestSweepWaitsOutTheGrace pins the read window before a sweep may close.
func TestSweepWaitsOutTheGrace(t *testing.T) {
	panes := []tmux.Pane{other, dead(runPane(pane("%1", "@1"), "run-grace"), 1)}
	check(t, sweep(panes, nil, now))
}

// TestSweepNeverTouchesAnUnmarkedWindow: a stale state record naming a
// pane id tmux has since reused must not let either rule reach it - only
// a window carrying @kido_run is ever a candidate.
func TestSweepNeverTouchesAnUnmarkedWindow(t *testing.T) {
	stale := state.Session{Pane: "%1", PID: os.Getpid(),
		ID: "child-sess", Parent: state.NewParent("long-gone-sess", 0)}
	panes := []tmux.Pane{other, dead(pane("%1", "@1"), 600)}
	check(t, sweep(panes, []state.Session{stale}, now))
}

func TestSweepNeverClosesASessionsLastWindow(t *testing.T) {
	panes := []tmux.Pane{dead(runPane(pane("%1", "@1"), "run-lastwindow"), 600)}
	check(t, sweep(panes, nil, now))
}

// TestSweepCollectsAFocusedWindowOnceTheUserLeaves: a focused window is
// left alone, then collected as soon as the user switches away.
func TestSweepCollectsAFocusedWindowOnceTheUserLeaves(t *testing.T) {
	finished := dead(runPane(pane("%1", "@1"), "run-read"), 600)
	check(t, sweep([]tmux.Pane{other, watched(finished)}, nil, now))
	check(t, sweep([]tmux.Pane{watched(other), finished}, nil, now), winClose("@1"))
}

// TestSweepCancelsSubagentOfDeadParent is rule 2: the subagent is alive
// and its window is not dead, so only its parent's absence can close it.
func TestSweepCancelsSubagentOfDeadParent(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	child := state.Session{Pane: "%1", PID: os.Getpid(),
		ID: "child-sess", Parent: state.NewParent("root-sess", 0)}
	parent := state.Session{Pane: "%p", PID: testutil.DeadPID(t), ID: "root-sess"}
	panes := []tmux.Pane{other, runPane(pane("%1", "@1"), "run-cancelled")}
	check(t, sweep(panes, []state.Session{child, parent}, now), winClose("@1"))
}

// TestSweepSurvivesAPaneCollisionOnTheParent: a second live agent that
// claims the parent's pane (a `pi --print` inheriting TMUX_PANE) must
// not make Sweep, given the complete record set (state.LoadLive), treat
// the parent as dead. The per-pane view (state.Load) is swept too as a
// negative control: it is the input that caused the real incident, and
// must still close the window and record a false ending.
func TestSweepSurvivesAPaneCollisionOnTheParent(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	bashRun(t, "run-collision", "build", "parent-sess")
	live := time.Now()
	record(t, "parent-sess", state.Session{Pane: "%p", PID: os.Getpid(),
		Agent: state.AgentPi, TS: live})
	record(t, "child-sess", state.Session{Pane: "%1", PID: os.Getpid(),
		Agent: state.AgentPi, Parent: state.NewParent("parent-sess", 0), TS: live})
	record(t, "intruder-sess", state.Session{Pane: "%p", PID: os.Getpid(),
		Agent: state.AgentPi, TS: live.Add(time.Second)})
	panes := []tmux.Pane{other, runPane(pane("%1", "@1"), "run-collision")}

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
	if _, ok := byPane["%p"]; !ok || byPane["%p"].ID != "intruder-sess" {
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

// TestBashEndingNamesTheRun pins that the notice text itself carries the
// run's name, status and output - a bash run writes no state record for
// the receiving extension to label the sender from.
func TestBashEndingNamesTheRun(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := subrun.Create("run-named", "x"); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(subrun.OutputPath("run-named"), []byte("boom\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	e := Ending{Meta: subrun.Meta{ID: "run-named", Name: "build"},
		Outcome: subrun.Outcome{Result: subrun.Failed, Text: "exit status 3"}}
	text := BashEnding{}.body(e)
	for _, want := range []string{`"build"`, "failed", "exit status 3", "run-named", "boom"} {
		if !strings.Contains(text, want) {
			t.Errorf("notice = %q, want it to carry %q", text, want)
		}
	}

	unnamed := Ending{Meta: subrun.Meta{ID: "run-named"},
		Outcome: subrun.Outcome{Result: subrun.Completed, Text: "exit status 0"}}
	if text := (BashEnding{}).body(unnamed); !strings.Contains(text, "run-named") {
		t.Errorf("unnamed run's notice = %q, want it to fall back to the run id", text)
	}
}

// TestTailOfFileKeepsTheEnd pins the direction of the cut: the tail, not
// the head.
func TestTailOfFileKeepsTheEnd(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/output"
	var b strings.Builder
	for i := 0; i < 1000; i++ {
		fmt.Fprintf(&b, "line %04d\n", i)
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		t.Fatal(err)
	}

	tail, omitted, err := tailOfFile(path, maxNoticeTailBytes)
	if err != nil {
		t.Fatal(err)
	}
	if len(tail) != maxNoticeTailBytes {
		t.Errorf("tail is %d bytes, want the %d byte cap", len(tail), maxNoticeTailBytes)
	}
	if want := int64(b.Len() - maxNoticeTailBytes); omitted != want {
		t.Errorf("omitted = %d, want %d", omitted, want)
	}
	if !strings.HasSuffix(tail, "line 0999\n") {
		t.Errorf("tail ends %q, want the last line of the file", tail[len(tail)-20:])
	}
	if strings.Contains(tail, "line 0000\n") {
		t.Errorf("tail = %q..., want the head of the file dropped", tail[:20])
	}

	short := dir + "/short"
	if err := os.WriteFile(short, []byte("all of it\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if tail, omitted, err := tailOfFile(short, maxNoticeTailBytes); err != nil || omitted != 0 || tail != "all of it\n" {
		t.Errorf("tailOfFile(short) = %q, %d, %v, want the whole file and nothing omitted", tail, omitted, err)
	}
}

// TestTailOfFileDropsPartialRune pins tailOfFile's cut: anywhere inside
// a 4-byte rune, it must produce valid UTF-8 with exactly that rune
// dropped.
func TestTailOfFileDropsPartialRune(t *testing.T) {
	const r = "🎉"
	s := "ab" + r + "cd"
	start := strings.Index(s, r)
	for cut := start + 1; cut < start+len(r); cut++ {
		t.Run(fmt.Sprintf("cut=%d", cut), func(t *testing.T) {
			path := t.TempDir() + "/output"
			if err := os.WriteFile(path, []byte(s), 0o644); err != nil {
				t.Fatal(err)
			}
			tail, _, err := tailOfFile(path, int64(len(s)-cut))
			if err != nil {
				t.Fatal(err)
			}
			if !utf8.ValidString(tail) {
				t.Errorf("tailOfFile cut at %d is not valid UTF-8: %q", cut, tail)
			}
			if tail != s[start+len(r):] {
				t.Errorf("tailOfFile cut at %d = %q, want %q (the partial rune dropped)", cut, tail, s[start+len(r):])
			}
		})
	}
}

// TestTailOfFileIsValidUTF8: the send path refuses a message that is not
// valid UTF-8, so a log cut mid-character must not produce one.
func TestTailOfFileIsValidUTF8(t *testing.T) {
	path := t.TempDir() + "/output"
	if err := os.WriteFile(path, []byte(strings.Repeat("☃", 10)), 0o644); err != nil {
		t.Fatal(err)
	}
	tail, omitted, err := tailOfFile(path, 4)
	if err != nil {
		t.Fatal(err)
	}
	if !utf8.ValidString(tail) {
		t.Errorf("tail = %q, want valid UTF-8", tail)
	}
	if omitted != 27 {
		t.Errorf("omitted = %d, want 27: the two bytes of the partial rune count as dropped too", omitted)
	}
	if tail != "☃" {
		t.Errorf("tail = %q, want the one whole rune that fits", tail)
	}
}

func record(t *testing.T, id string, s state.Session) {
	t.Helper()
	if err := state.Record(id, s); err != nil {
		t.Fatal(err)
	}
}

func TestSweepLeavesSubagentOfLiveParentAlone(t *testing.T) {
	child := state.Session{Pane: "%1", PID: os.Getpid(),
		ID: "child-sess", Parent: state.NewParent("root-sess", 0)}
	parent := state.Session{Pane: "%p", PID: os.Getpid(), ID: "root-sess"}
	panes := []tmux.Pane{other, runPane(pane("%1", "@1"), "run-live-parent")}
	check(t, sweep(panes, []state.Session{child, parent}, now))
}

// TestSweepNeverTouchesARootAgent: a record with no ParentSession is
// nobody's to close, even with its window marked and its process gone.
func TestSweepNeverTouchesARootAgent(t *testing.T) {
	root := state.Session{Pane: "%1", PID: testutil.DeadPID(t), ID: "root-sess"}
	panes := []tmux.Pane{other, runPane(pane("%1", "@1"), "run-root")}
	check(t, sweep(panes, []state.Session{root}, now))
}

// TestSweepReturnsAWindowOnce: both rules can name the same window and
// it must still be closed once.
func TestSweepReturnsAWindowOnce(t *testing.T) {
	child := state.Session{Pane: "%1", PID: os.Getpid(),
		ID: "child-sess", Parent: state.NewParent("gone-sess", 0)}
	panes := []tmux.Pane{other, dead(runPane(pane("%1", "@1"), "run-once"), 600)}
	check(t, sweep(panes, []state.Session{child}, now), winClose("@1"))
}

func TestSweepRecordsDiedForAWindowItCloses(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := subrun.Create("run-died", "x"); err != nil {
		t.Fatal(err)
	}
	panes := []tmux.Pane{other, dead(runPane(pane("%1", "@1"), "run-died"), 60)}
	check(t, sweep(panes, nil, now), winClose("@1"))

	got, ok, err := subrun.ReadOutcome("run-died")
	if err != nil || !ok {
		t.Fatalf("ReadOutcome = %+v, %v, %v", got, ok, err)
	}
	if got.Result != subrun.Died {
		t.Errorf("outcome = %q, want %q", got.Result, subrun.Died)
	}
}

func TestSweepDoesNotOverwriteARecordedOutcome(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := subrun.Create("run-done", "x"); err != nil {
		t.Fatal(err)
	}
	if err := subrun.RecordOutcome("run-done", subrun.Outcome{Result: subrun.Completed, At: now}); err != nil {
		t.Fatal(err)
	}
	panes := []tmux.Pane{other, dead(runPane(pane("%1", "@1"), "run-done"), 60)}
	check(t, sweep(panes, nil, now), winClose("@1"))

	got, ok, err := subrun.ReadOutcome("run-done")
	if err != nil || !ok || got.Result != subrun.Completed {
		t.Errorf("outcome = %+v, %v, %v, want it to stay %q", got, ok, err, subrun.Completed)
	}
}

// stubCapture replaces subrun.CapturePane with one that returns text for
// a fixed pane id and an error for any other.
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

// TestSweepCapturesScreenBeforeClosing pins that the screen is written
// before the window can be gone.
func TestSweepCapturesScreenBeforeClosing(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := subrun.Create("run-crash", "x"); err != nil {
		t.Fatal(err)
	}
	stubCapture(t, "%1", "panic: something went wrong\n")

	panes := []tmux.Pane{other, dead(runPane(pane("%1", "@1"), "run-crash"), 60)}
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
// reasons: neither may leave a screen behind.
func TestSweepCapturesNothingForAWindowItRefusesToClose(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := subrun.Create("run-focused", "x"); err != nil {
		t.Fatal(err)
	}
	stubCapture(t, "%1", "should never be written")

	finished := dead(runPane(pane("%1", "@1"), "run-focused"), 600)
	check(t, sweep([]tmux.Pane{other, watched(finished)}, nil, now))

	if _, ok, err := subrun.ReadScreen("run-focused"); err != nil || ok {
		t.Fatalf("ReadScreen ok = %v, err = %v, want no screen for a window Sweep refused to close", ok, err)
	}

	if err := subrun.Create("run-lastwindow", "x"); err != nil {
		t.Fatal(err)
	}
	solo := []tmux.Pane{dead(runPane(pane("%2", "@2"), "run-lastwindow"), 600)}
	check(t, sweep(solo, nil, now))
	if _, ok, err := subrun.ReadScreen("run-lastwindow"); err != nil || ok {
		t.Fatalf("ReadScreen ok = %v, err = %v, want no screen for a session's last window", ok, err)
	}
}

func TestSweepClosesEvenWhenCaptureFails(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := subrun.Create("run-nopane", "x"); err != nil {
		t.Fatal(err)
	}
	stubCapture(t, "%never-matches", "unreachable")

	panes := []tmux.Pane{other, dead(runPane(pane("%1", "@1"), "run-nopane"), 60)}
	check(t, sweep(panes, nil, now), winClose("@1"))

	if _, ok, err := subrun.ReadScreen("run-nopane"); err != nil || ok {
		t.Fatalf("ReadScreen ok = %v, err = %v, want no screen after a failed capture", ok, err)
	}
}

// TestSweepBoundsTheCapturedScreen pins subrun.MaxScreenBytes.
func TestSweepBoundsTheCapturedScreen(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := subrun.Create("run-huge", "x"); err != nil {
		t.Fatal(err)
	}
	huge := strings.Repeat("x", subrun.MaxScreenBytes*2) + "TAIL"
	stubCapture(t, "%1", huge)

	panes := []tmux.Pane{other, dead(runPane(pane("%1", "@1"), "run-huge"), 60)}
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

// bashRun writes the meta a `kido async_bash` window's run has. parent
// may be empty, which is a run started from a shell nobody was tracking.
func bashRun(t *testing.T, id subrun.ID, name, parent string) {
	t.Helper()
	if err := subrun.Create(id, "make -j8"); err != nil {
		t.Fatal(err)
	}
	if err := subrun.WriteMeta(subrun.Meta{ID: id, Name: name, Kind: subrun.KindBash,
		ParentSession: parent}); err != nil {
		t.Fatal(err)
	}
}

func notices(t *testing.T, panes []tmux.Pane, sessions []state.Session) []Ending {
	t.Helper()
	_, out := Sweep(panes, sessions, now)
	return out
}

// TestSweepNotifiesForABashRunNobodyReported: an ending the wrapper
// never got to record (SIGKILL, a window closed by hand) still notifies
// the parent.
func TestSweepNotifiesForABashRunNobodyReported(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	bashRun(t, "run-killed", "build", "root-sess")
	panes := []tmux.Pane{other, dead(runPane(pane("%1", "@1"), "run-killed"), 60)}

	got := notices(t, panes, nil)
	if len(got) != 1 {
		t.Fatalf("Sweep returned %d notices, want exactly 1: %+v", len(got), got)
	}
	if got[0].Meta.Name != "build" || got[0].Meta.ParentSession != "root-sess" {
		t.Errorf("notice names %+v, want the run's own name and parent", got[0].Meta)
	}
	const wantText = "ended without its wrapper reporting"
	if got[0].Outcome.Result != subrun.Failed || got[0].Outcome.Text != wantText {
		t.Errorf("notice carries %+v, want %q/%q", got[0].Outcome, subrun.Failed, wantText)
	}
	o, ok, err := subrun.ReadOutcome("run-killed")
	if err != nil || !ok || o.Result != subrun.Failed || o.Text != wantText {
		t.Errorf("ReadOutcome = %+v, %v, %v, want the same story on disk", o, ok, err)
	}
}

// TestSweepSaysNothingForABashRunItsWrapperReported is the negative
// control for the test above: a wrapper that already recorded the ending
// must get no second notice from the sweep.
func TestSweepSaysNothingForABashRunItsWrapperReported(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	bashRun(t, "run-told", "build", "root-sess")
	if err := subrun.RecordOutcome("run-told", subrun.Outcome{
		Result: subrun.Failed, Text: "exit status 3", At: now}); err != nil {
		t.Fatal(err)
	}
	panes := []tmux.Pane{other, dead(runPane(pane("%1", "@1"), "run-told"), 60)}

	closing, got := Sweep(panes, nil, now)
	check(t, closing, winClose("@1"))
	if len(got) != 0 {
		t.Errorf("Sweep returned %+v, want nothing: the wrapper already reported this ending", got)
	}
	if o, _, _ := subrun.ReadOutcome("run-told"); o.Text != "exit status 3" {
		t.Errorf("outcome = %+v, want the wrapper's own story to stand", o)
	}
}

// TestSweepNotifiesOnceUnderTwoObservers: two sweeps of the same ending
// (a sidebar per client, plus `kido reap`) must produce exactly one
// notice between them.
func TestSweepNotifiesOnceUnderTwoObservers(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	bashRun(t, "run-raced", "build", "root-sess")
	panes := []tmux.Pane{other, dead(runPane(pane("%1", "@1"), "run-raced"), 60)}

	total := len(notices(t, panes, nil)) + len(notices(t, panes, nil))
	if total != 1 {
		t.Errorf("two sweeps of one ending produced %d notices, want exactly 1", total)
	}
}

// agentRun writes the meta a `kido spawn_subagent` window's run has: no
// Kind at all, which every reader takes as an agent run.
func agentRun(t *testing.T, id subrun.ID, name, parent string) {
	t.Helper()
	if err := subrun.Create(id, "do a thing"); err != nil {
		t.Fatal(err)
	}
	if err := subrun.WriteMeta(subrun.Meta{ID: id, Name: name, ParentSession: parent}); err != nil {
		t.Fatal(err)
	}
}

// TestSweepNotifiesForAnAgentRunNobodyReported: a child's window found
// gone or dead with no outcome recorded notifies the parent that it
// ended and nothing was said about it - not a verdict on the work.
func TestSweepNotifiesForAnAgentRunNobodyReported(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	agentRun(t, "run-agent", "kid", "root-sess")
	panes := []tmux.Pane{other, dead(runPane(pane("%1", "@1"), "run-agent"), 60)}

	closing, got := Sweep(panes, nil, now)
	check(t, closing, winClose("@1"))
	if len(got) != 1 {
		t.Fatalf("Sweep returned %d notices for an unreported agent run, want exactly 1: %+v", len(got), got)
	}
	if got[0].Meta.Name != "kid" || got[0].Meta.ParentSession != "root-sess" {
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
// for the test above: a child that already recorded its own outcome must
// get no second notice from the sweep.
func TestSweepSaysNothingForAnAgentRunThatReported(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	agentRun(t, "run-said", "kid", "root-sess")
	if err := subrun.RecordOutcome("run-said", subrun.Outcome{Result: subrun.Completed, At: now}); err != nil {
		t.Fatal(err)
	}
	panes := []tmux.Pane{other, dead(runPane(pane("%1", "@1"), "run-said"), 60)}

	closing, got := Sweep(panes, nil, now)
	check(t, closing, winClose("@1"))
	if len(got) != 0 {
		t.Errorf("Sweep returned %+v, want nothing: this run's own child already spoke for it", got)
	}
	if o, _, _ := subrun.ReadOutcome("run-said"); o.Result != subrun.Completed {
		t.Errorf("outcome = %+v, want the child's own story to stand", o)
	}
}

// TestSweepNotifiesNobodyForAParentlessBashRun: a run with no parent
// session sends no notice, but the ending is still recorded.
func TestSweepNotifiesNobodyForAParentlessBashRun(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	bashRun(t, "run-loner", "build", "")
	panes := []tmux.Pane{other, dead(runPane(pane("%1", "@1"), "run-loner"), 60)}

	if got := notices(t, panes, nil); len(got) != 0 {
		t.Errorf("Sweep returned %+v, want nothing: this run has no parent to tell", got)
	}
	if o, ok, _ := subrun.ReadOutcome("run-loner"); !ok || o.Result != subrun.Failed {
		t.Errorf("outcome = %+v (recorded %v), want the ending recorded regardless", o, ok)
	}
}

// TestSweepClosesTheRunsPaneAndLeavesTheSplit: a shell the user split
// into a subagent's window is left standing when the run's own pane is
// collected.
func TestSweepClosesTheRunsPaneAndLeavesTheSplit(t *testing.T) {
	run := dead(runPane(pane("%1", "@1"), "run-split"), 600)
	shell := pane("%2", "@1")
	check(t, sweep([]tmux.Pane{other, run, shell}, nil, now), paneClose("@1", "%1"))
}

// TestSweepClosesTheWindowWhenTheRunsPaneIsAllOfIt is the negative
// control for the test above: with no split, the run's pane is the whole
// window and closing it is a window close, not a pane close.
func TestSweepClosesTheWindowWhenTheRunsPaneIsAllOfIt(t *testing.T) {
	run := dead(runPane(pane("%1", "@1"), "run-solo"), 600)
	check(t, sweep([]tmux.Pane{other, run}, nil, now), winClose("@1"))
}

// TestSweepStillWaitsForTheGraceOnARunsPane: the grace period is
// measured from the run's own pane death, not the window's.
func TestSweepStillWaitsForTheGraceOnARunsPane(t *testing.T) {
	run := dead(runPane(pane("%1", "@1"), "run-young"), 1)
	shell := pane("%2", "@1")
	check(t, sweep([]tmux.Pane{other, run, shell}, nil, now))
}

func TestSweepLeavesALiveRunsPaneAlone(t *testing.T) {
	run := runPane(pane("%1", "@1"), "run-going")
	corpse := dead(pane("%2", "@1"), 600)
	check(t, sweep([]tmux.Pane{other, run, corpse}, nil, now))
}

// TestSweepRefusesTheRunsPaneInAFocusedWindow: the focus refusal applies
// to a pane close too, then collects once the user moves on.
func TestSweepRefusesTheRunsPaneInAFocusedWindow(t *testing.T) {
	run := dead(runPane(pane("%1", "@1"), "run-read"), 600)
	shell := watched(pane("%2", "@1"))
	check(t, sweep([]tmux.Pane{other, run, shell}, nil, now))

	shell.Active, shell.SessionAttached = false, true
	check(t, sweep([]tmux.Pane{watched(other), run, shell}, nil, now), paneClose("@1", "%1"))
}

// TestSweepClosesARunsPaneInASessionsLastWindow: the last-window refusal
// does not apply to killing one pane of a window that has another.
func TestSweepClosesARunsPaneInASessionsLastWindow(t *testing.T) {
	run := dead(runPane(pane("%1", "@1"), "run-last"), 600)
	shell := pane("%2", "@1")
	check(t, sweep([]tmux.Pane{run, shell}, nil, now), paneClose("@1", "%1"))
}

func TestSweepCapturesOnlyTheRunsPane(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := subrun.Create("run-screen", "x"); err != nil {
		t.Fatal(err)
	}
	stubCapture(t, "%1", "the run's last screen\n")

	run := dead(runPane(pane("%1", "@1"), "run-screen"), 600)
	shell := pane("%2", "@1")
	check(t, sweep([]tmux.Pane{other, run, shell}, nil, now), paneClose("@1", "%1"))

	got, ok, err := subrun.ReadScreen("run-screen")
	if err != nil || !ok {
		t.Fatalf("ReadScreen = %q, %v, %v", got, ok, err)
	}
	if got != "the run's last screen\n" {
		t.Errorf("screen = %q, want the run's pane alone and no pane-labelled blocks", got)
	}
}

// TestSweepNotifiesOnceForARunsPane: the exactly-once invariant holds
// for a pane close too.
func TestSweepNotifiesOnceForARunsPane(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	bashRun(t, "run-paned", "build", "root-sess")
	run := dead(runPane(pane("%1", "@1"), "run-paned"), 600)
	shell := pane("%2", "@1")
	panes := []tmux.Pane{other, run, shell}

	total := len(notices(t, panes, nil)) + len(notices(t, panes, nil))
	if total != 1 {
		t.Errorf("two sweeps of one ending produced %d notices, want exactly 1", total)
	}
	if o, ok, _ := subrun.ReadOutcome("run-paned"); !ok || o.Result != subrun.Failed {
		t.Errorf("outcome = %+v (recorded %v), want the ending recorded before the pane is killed", o, ok)
	}
}

// TestSweepCancelsAnOrphanByItsOwnPane is rule 2 with a split: a
// bystander pane the user split into the window is left alone.
func TestSweepCancelsAnOrphanByItsOwnPane(t *testing.T) {
	child := state.Session{Pane: "%1", PID: os.Getpid(),
		ID: "child-sess", Parent: state.NewParent("root-sess", 0)}
	parent := state.Session{Pane: "%p", PID: testutil.DeadPID(t), ID: "root-sess"}
	panes := []tmux.Pane{other, runPane(pane("%1", "@1"), "run-orphan"), pane("%2", "@1")}
	check(t, sweep(panes, []state.Session{child, parent}, now), paneClose("@1", "%1"))
}

// TestSweepLeavesAChildOfARestartedParentAlone: a parent's session id
// surviving a `pi --resume` restart (new PID, same session id) must not
// orphan its children.
func TestSweepLeavesAChildOfARestartedParentAlone(t *testing.T) {
	child := state.Session{ID: "child-sess", Pane: "%1", PID: os.Getpid(),
		Parent: state.NewParent("parent-sess", 0)}
	parent := state.Session{ID: "parent-sess", Pane: "%p", PID: os.Getpid()}
	panes := []tmux.Pane{other, runPane(pane("%1", "@1"), "run-restarted")}
	check(t, sweep(panes, []state.Session{child, parent}, now))
}
