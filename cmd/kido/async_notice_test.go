package main

import (
	"strings"
	"testing"
	"time"

	"kido/internal/msg"
	"kido/internal/state"
	"kido/internal/subrun"
	"kido/internal/testutil"
	"kido/internal/tmux"
)

// noticeParent records a parent agent on %2 with a live inbox and puts
// the caller on %1, which is the shape every observer of a run's ending
// sends from: a process whose own pane is not the parent's.
func noticeParent(t *testing.T, instance string) *testutil.Inbox {
	t.Helper()
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, []tmux.Pane{
		{PaneID: "%1", SessionID: "$1", WindowID: "@1"},
		{PaneID: "%2", SessionID: "$1", WindowID: "@2"},
	})
	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("parent", state.Session{
		Agent: state.AgentPi, Pane: "%2", PID: 1, Status: state.Idle, Title: "orchestrator",
		Instance: instance, Inbox: in.Path, Protocol: msg.V1,
	}); err != nil {
		t.Fatal(err)
	}
	return in
}

// envelopes parses everything an inbox received, failing on anything
// that is not a v1 envelope.
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

// TestAsyncNoticeSaysItIsFromTheRun pins the sender's name. A bash run
// writes no state record, so the From kido can fill in names whichever
// process observed the ending - the wrapper's own pane, which is no
// agent, leaving a parent reading "notification from %47", or worse the
// unrelated agent that typed `kido stop_subagent`. The run's name is the
// only honest answer and the only one a model can act on.
func TestAsyncNoticeSaysItIsFromTheRun(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	in := noticeParent(t, "root-inst")
	t.Setenv("KIDO_AGENT_PARENT_INSTANCE", "root-inst")

	id := startAsyncRun(t, "true")
	captureStdout(t, func() { asyncRunCmd([]string{"--run-id", id, "--name", "build"}) })

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
// gone: marked with the run, every pane a remain-on-exit corpse, dead
// long enough for the linger to have passed. The second window keeps the
// sweep off the last-window rule.
func deadRunWindow(runID string) []tmux.Pane {
	return []tmux.Pane{
		{PaneID: "%2", SessionID: "$1", WindowID: "@2"},
		{PaneID: "%9", SessionID: "$1", WindowID: "@9",
			Subagent: tmux.SubagentMark(runID, "root-inst", 1),
			Dead:     true, DeadTime: time.Now().Add(-time.Hour).Unix()},
	}
}

// withKillWindow records what a sweep closes instead of talking to tmux.
func withKillWindow(t *testing.T) func() []string {
	t.Helper()
	var closed []string
	prev := killWindow
	killWindow = func(id string) error {
		closed = append(closed, id)
		return nil
	}
	t.Cleanup(func() { killWindow = prev })
	return func() []string { return closed }
}

// startedRun writes the run `kido async_bash` would have left behind:
// kind bash, a parent to tell, and some output for the notice to carry.
func startedRun(t *testing.T, name, parent string) subrun.Meta {
	t.Helper()
	meta := subrun.Meta{ID: startAsyncRun(t, "sleep", "600"), Name: name, Kind: subrun.KindBash,
		ParentInstance: parent, Pane: "%9", Window: "@9", StartedAt: time.Now()}
	if err := subrun.WriteMeta(meta); err != nil {
		t.Fatal(err)
	}
	return meta
}

// TestReapNotifiesForARunWhoseWrapperNeverSpoke is the exactly-once
// invariant from the command an operator (or a test) types: the ending
// nobody saw still reaches the parent, once, with the run's name on it.
// The wrapper is never run here at all, which is the whole scenario -
// SIGKILLed, or taken down with its window, it never got to report.
func TestReapNotifiesForARunWhoseWrapperNeverSpoke(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	in := noticeParent(t, "root-inst")
	meta := startedRun(t, "doomed", "root-inst")
	withPanes(t, deadRunWindow(meta.ID))
	closed := withKillWindow(t)

	captureStdout(t, func() {
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

	// The second sweep sees exactly what the first saw - the window is
	// only closed in the fake above - so anything it sends is a second
	// notice for one ending.
	captureStdout(t, func() {
		if err := reapCmd(nil); err != nil {
			t.Fatal(err)
		}
	})
	if got := in.Received(); len(got) != 1 {
		t.Errorf("after a second reap the parent holds %d envelopes, want still 1: %q", len(got), got)
	}
}

// TestReapSaysNothingForARunItsWrapperReported is the negative control
// that carries the invariant, and without it every assertion above
// passes against a reap that notifies unconditionally. The window here
// is indistinguishable from the one above; only the outcome already on
// disk tells them apart, and reading it is the whole mechanism.
func TestReapSaysNothingForARunItsWrapperReported(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	in := noticeParent(t, "root-inst")
	meta := startedRun(t, "told", "root-inst")
	if err := subrun.RecordOutcome(meta.ID, subrun.Outcome{
		Result: subrun.Failed, Text: "exit status 3", At: time.Now()}); err != nil {
		t.Fatal(err)
	}
	withPanes(t, deadRunWindow(meta.ID))
	closed := withKillWindow(t)

	captureStdout(t, func() {
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
