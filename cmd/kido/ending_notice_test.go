package main

import (
	"os"
	"strings"
	"testing"
	"time"

	"kido/internal/msg"
	"kido/internal/state"
	"kido/internal/subrun"
	"kido/internal/testutil"
	"kido/internal/tmux"
)

func noticeParent(t *testing.T, session string) *testutil.Inbox {
	t.Helper()
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, []tmux.Pane{
		{PaneID: "%1", SessionID: "$1", WindowID: "@1"},
		{PaneID: "%2", SessionID: "$1", WindowID: "@2"},
	})
	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record(session, state.Session{
		Agent: state.AgentPi, Pane: "%2", PID: 1, Status: state.Idle, Title: "orchestrator",
		Inbox: in.Path,
	}); err != nil {
		t.Fatal(err)
	}
	return in
}

func envelopes(t *testing.T, in *testutil.Inbox) []msg.Envelope {
	t.Helper()
	var out []msg.Envelope
	for _, raw := range in.Received() {
		env, ok := msg.Parse([]byte(raw))
		if !ok {
			t.Fatalf("inbox received %q, which is not a v1 envelope", raw)
		}
		out = append(out, env)
	}
	return out
}

// TestAsyncNoticeSaysItIsFromTheRun pins the sender's name: a bash run
// writes no state record, so the run's own name is the only honest
// answer for From.
func TestAsyncNoticeSaysItIsFromTheRun(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	in := noticeParent(t, "root-sess")

	id := startAsyncRun(t, "build", "root-sess", "true")
	capture(t, &os.Stdout, func() { asyncRunCmd([]string{"--run-id", string(id)}) })

	got := envelopes(t, in)
	if len(got) != 1 {
		t.Fatalf("parent received %d envelopes, want 1: %+v", len(got), got)
	}
	if got[0].Kind != msg.KindNotice {
		t.Errorf("envelope kind = %q, want %q", got[0].Kind, msg.KindNotice)
	}
	if got[0].From.Name != "build" {
		t.Errorf("notice is from %+v, want it to name the run: \"build\"", got[0].From)
	}
	if !strings.Contains(got[0].Text, "exit status 0") {
		t.Errorf("notice text = %q, want the run's exit status", got[0].Text)
	}
}

// deadRunWindow is the pane list a sweep sees once a run's window has
// gone, dead long enough for the linger to have passed. The second
// window keeps the sweep off the last-window rule.
func deadRunWindow(runID subrun.ID) []tmux.Pane {
	return []tmux.Pane{
		{PaneID: "%2", SessionID: "$1", WindowID: "@2"},
		{PaneID: "%9", SessionID: "$1", WindowID: "@9", Run: string(runID),
			DeadAt: time.Now().Add(-time.Hour).Unix()},
	}
}

func withKillWindow(t *testing.T) func() []string {
	t.Helper()
	var closed []string
	testutil.Swap(t, &killWindow, func(id string) error {
		closed = append(closed, id)
		return nil
	})
	return func() []string { return closed }
}

func startedRun(t *testing.T, name, parent string) subrun.Meta {
	t.Helper()
	meta := subrun.Meta{ID: startAsyncRun(t, name, parent, "sleep", "600"), Name: name, Kind: subrun.KindBash,
		ParentSession: parent, Pane: "%9", StartedAt: time.Now()}
	if err := subrun.WriteMeta(meta); err != nil {
		t.Fatal(err)
	}
	return meta
}

// TestReapNotifiesForARunWhoseWrapperNeverSpoke: an ending nobody saw
// (the wrapper is never run here at all) still reaches the parent, once,
// with the run's name on it.
func TestReapNotifiesForARunWhoseWrapperNeverSpoke(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	in := noticeParent(t, "root-sess")
	meta := startedRun(t, "doomed", "root-sess")
	withPanes(t, deadRunWindow(meta.ID))
	closed := withKillWindow(t)

	capture(t, &os.Stdout, func() {
		if err := reapCmd(nil); err != nil {
			t.Fatal(err)
		}
	})
	if got := closed(); len(got) != 1 || got[0] != "@9" {
		t.Errorf("reap closed %v, want the run's own window", got)
	}

	got := envelopes(t, in)
	if len(got) != 1 {
		t.Fatalf("parent received %d envelopes, want exactly 1: %+v", len(got), got)
	}
	if got[0].From.Name != "doomed" || !strings.Contains(got[0].Text, "doomed") {
		t.Errorf("notice = %+v, want it to name the run", got[0])
	}
	if !strings.Contains(got[0].Text, "failed") {
		t.Errorf("notice text = %q, want a failed ending", got[0].Text)
	}
	if o, ok, _ := subrun.ReadOutcome(meta.ID); !ok || o.Result != subrun.Failed {
		t.Errorf("outcome = %+v (recorded %v), want failed", o, ok)
	}

	capture(t, &os.Stdout, func() {
		if err := reapCmd(nil); err != nil {
			t.Fatal(err)
		}
	})
	if got := in.Received(); len(got) != 1 {
		t.Errorf("after a second reap the parent holds %d envelopes, want still 1: %q", len(got), got)
	}
}

// TestReapSaysNothingForARunItsWrapperReported is the negative control:
// only the outcome already on disk tells the two windows apart.
func TestReapSaysNothingForARunItsWrapperReported(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	in := noticeParent(t, "root-sess")
	meta := startedRun(t, "told", "root-sess")
	if err := subrun.RecordOutcome(meta.ID, subrun.Outcome{
		Result: subrun.Failed, Text: "exit status 3", At: time.Now()}); err != nil {
		t.Fatal(err)
	}
	withPanes(t, deadRunWindow(meta.ID))
	closed := withKillWindow(t)

	capture(t, &os.Stdout, func() {
		if err := reapCmd(nil); err != nil {
			t.Fatal(err)
		}
	})
	if got := closed(); len(got) != 1 {
		t.Errorf("reap closed %v, want the window collected regardless", got)
	}
	if got := in.Received(); len(got) != 0 {
		t.Errorf("parent received %q, want nothing: the wrapper already reported this ending", got)
	}
	if o, _, _ := subrun.ReadOutcome(meta.ID); o.Text != "exit status 3" {
		t.Errorf("outcome = %+v, want the wrapper's own story to stand", o)
	}
}

func startedAgentRun(t *testing.T, name, parent string) subrun.Meta {
	t.Helper()
	id := subrun.NewID()
	if err := subrun.Create(id, "do a thing"); err != nil {
		t.Fatal(err)
	}
	meta := subrun.Meta{ID: id, Name: name, ParentSession: parent,
		Pane: "%9", StartedAt: time.Now()}
	if err := subrun.WriteMeta(meta); err != nil {
		t.Fatal(err)
	}
	return meta
}

// TestReapNotifiesForAnAgentRunNobodyReported: a child that never ran
// at all - killed, reaped, or crashed before it reached notify_parent -
// left a marked window and nothing else, and a sweep still reports it.
func TestReapNotifiesForAnAgentRunNobodyReported(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	in := noticeParent(t, "root-sess")
	meta := startedAgentRun(t, "ttyfix", "root-sess")
	withPanes(t, deadRunWindow(meta.ID))
	withKillWindow(t)

	capture(t, &os.Stdout, func() {
		if err := reapCmd(nil); err != nil {
			t.Fatal(err)
		}
	})

	got := envelopes(t, in)
	if len(got) != 1 {
		t.Fatalf("parent received %d envelopes, want exactly 1: %+v", len(got), got)
	}
	if got[0].From.Name != "ttyfix" {
		t.Errorf("notice is from %+v, want it to name the run", got[0].From)
	}
	for _, want := range []string{"ttyfix", string(subrun.Died), string(meta.ID), "spawn_subagent(resume: \"" + string(meta.ID) + "\")"} {
		if !strings.Contains(got[0].Text, want) {
			t.Errorf("notice text = %q, want it to carry %q", got[0].Text, want)
		}
	}
}

// TestReapNoticeClaimsOnlyWhatTheSweepKnows: a sweep reads the window
// and the outcome file and nothing else, so whether a child actually
// reported is not among what it can know, and its notice must not say
// either way.
func TestReapNoticeClaimsOnlyWhatTheSweepKnows(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	in := noticeParent(t, "root-sess")
	meta := startedAgentRun(t, "simp-merge", "root-sess")
	withPanes(t, deadRunWindow(meta.ID))
	withKillWindow(t)

	capture(t, &os.Stdout, func() {
		if err := reapCmd(nil); err != nil {
			t.Fatal(err)
		}
	})

	got := envelopes(t, in)
	if len(got) != 1 {
		t.Fatalf("parent received %d envelopes, want exactly 1: %+v", len(got), got)
	}
	for _, claim := range []string{"never called notify_parent", "without reporting", "whole account"} {
		if strings.Contains(got[0].Text, claim) {
			t.Errorf("notice text = %q, claims %q, which a sweep cannot know", got[0].Text, claim)
		}
	}
}

// TestRunOutcomeUnreportedNotifiesTheParent: a session shutting down
// without having called notify_parent records its outcome and, from the
// same write, tells its parent that is all there is going to be.
func TestRunOutcomeUnreportedNotifiesTheParent(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	in := noticeParent(t, "root-sess")
	meta := startedAgentRun(t, "ttyfix", "root-sess")

	if err := runOutcomeCmd([]string{"--result", "completed", "--unreported", string(meta.ID)}); err != nil {
		t.Fatal(err)
	}

	got := envelopes(t, in)
	if len(got) != 1 {
		t.Fatalf("parent received %d envelopes, want exactly 1: %+v", len(got), got)
	}
	if got[0].Kind != msg.KindNotice || got[0].From.Name != "ttyfix" {
		t.Errorf("envelope = %+v, want a notice from the run", got[0])
	}
	for _, want := range []string{"ttyfix", "never called notify_parent", string(subrun.Completed), string(meta.ID), "spawn_subagent(resume: \"" + string(meta.ID) + "\")"} {
		if !strings.Contains(got[0].Text, want) {
			t.Errorf("notice text = %q, want it to carry %q", got[0].Text, want)
		}
	}
	if o, ok, _ := subrun.ReadOutcome(meta.ID); !ok || o.Result != subrun.Completed {
		t.Errorf("outcome = %+v (recorded %v), want the child's own %q", o, ok, subrun.Completed)
	}
}

// TestRunOutcomeWithoutUnreportedSaysNothing is the negative control: a
// child that did call notify_parent gets no second notice on the way
// out.
func TestRunOutcomeWithoutUnreportedSaysNothing(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	in := noticeParent(t, "root-sess")
	meta := startedAgentRun(t, "ttyfix", "root-sess")

	if err := runOutcomeCmd([]string{"--result", "completed", string(meta.ID)}); err != nil {
		t.Fatal(err)
	}

	if got := in.Received(); len(got) != 0 {
		t.Errorf("parent received %q, want nothing: this child reported for itself", got)
	}
	if o, ok, _ := subrun.ReadOutcome(meta.ID); !ok || o.Result != subrun.Completed {
		t.Errorf("outcome = %+v (recorded %v), want it recorded regardless of the notice", o, ok)
	}
}

// TestRunOutcomeUnreportedThatLosesTheWriteSaysNothing: a run stopped
// from outside already has its `stopped` on disk and its stopper has
// already spoken, so the child's own shutdown finds the write taken and
// stays quiet.
func TestRunOutcomeUnreportedThatLosesTheWriteSaysNothing(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	in := noticeParent(t, "root-sess")
	meta := startedAgentRun(t, "ttyfix", "root-sess")
	if err := subrun.RecordOutcome(meta.ID, subrun.Outcome{Result: subrun.Stopped, At: time.Now()}); err != nil {
		t.Fatal(err)
	}

	if err := runOutcomeCmd([]string{"--result", "completed", "--unreported", string(meta.ID)}); err != nil {
		t.Fatal(err)
	}

	if got := in.Received(); len(got) != 0 {
		t.Errorf("parent received %q, want nothing: this ending was already spoken for", got)
	}
	if o, _, _ := subrun.ReadOutcome(meta.ID); o.Result != subrun.Stopped {
		t.Errorf("outcome = %+v, want the first writer's story to stand", o)
	}
}
