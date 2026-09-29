package main

import (
	"errors"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"kido/internal/msg"
	"kido/internal/state"
	"kido/internal/subrun"
	"kido/internal/testutil"
	"kido/internal/tmux"
)

func withKillPane(t *testing.T) func() []string {
	t.Helper()
	var calls []string
	testutil.Swap(t, &killPane, func(id string) error {
		calls = append(calls, id)
		return nil
	})
	return func() []string { return calls }
}

func TestStopNoForceRefusedAgainstInboxlessAgent(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	kills := withKillPane(t)

	if err := state.Record("target", state.Session{Pane: "%2", PID: os.Getpid(), Status: state.Idle}); err != nil {
		t.Fatal(err)
	}
	if err := stopSubagentCmd([]string{"target"}); err == nil {
		t.Fatal("stopSubagentCmd succeeded, want a refusal: target has no inbox and --force was not given")
	}
	if calls := kills(); len(calls) != 0 {
		t.Errorf("killPane calls = %v, want none without --force", calls)
	}
}

func TestStopForceKillsInboxlessAgent(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, []tmux.Pane{
		{PaneID: "%1", SessionID: "$1", WindowID: "@1"},
		{PaneID: "%2", SessionID: "$1", WindowID: "@2"},
	})
	kills := withKillPane(t)

	if err := state.Record("target", state.Session{Pane: "%2", PID: os.Getpid(), Status: state.Idle}); err != nil {
		t.Fatal(err)
	}
	if err := stopSubagentCmd([]string{"--force", "target"}); err != nil {
		t.Fatalf("stopSubagentCmd = %v, want success", err)
	}
	if calls := kills(); len(calls) != 1 || calls[0] != "%2" {
		t.Errorf("killPane calls = %v, want exactly one call for %%2", calls)
	}
}

// TestStopRefusesToKillASessionsOnlyWindow is refused by resolveTarget's
// session scope, before killRunPane's last-pane guard ever runs.
func TestStopRefusesToKillASessionsOnlyWindow(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, []tmux.Pane{
		{PaneID: "%1", SessionID: "$2", WindowID: "@9"},
		{PaneID: "%2", SessionID: "$1", WindowID: "@1"},
	})
	kills := withKillPane(t)

	if err := state.Record("target", state.Session{Pane: "%2", PID: os.Getpid(), Status: state.Idle}); err != nil {
		t.Fatal(err)
	}
	err := stopSubagentCmd([]string{"--force", "target"})
	if err == nil {
		t.Fatal("stopSubagentCmd succeeded, want a refusal")
	}
	if !strings.Contains(err.Error(), "another tmux session") {
		t.Errorf("error = %q, want the cross-session refusal, not the last-pane guard", err)
	}
	if calls := kills(); len(calls) != 0 {
		t.Errorf("killPane calls = %v, want none", calls)
	}
}

func TestStopKillsOneOfTwoPanesInAWindow(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, []tmux.Pane{
		{PaneID: "%1", SessionID: "$1", WindowID: "@1"},
		{PaneID: "%2", SessionID: "$1", WindowID: "@2"},
		{PaneID: "%3", SessionID: "$1", WindowID: "@2"}, // bystander, sharing @2 with the target
	})
	kills := withKillPane(t)

	if err := state.Record("target", state.Session{Pane: "%2", PID: os.Getpid(), Status: state.Idle}); err != nil {
		t.Fatal(err)
	}
	if err := stopSubagentCmd([]string{"--force", "target"}); err != nil {
		t.Fatalf("stopSubagentCmd = %v, want success: @2 has a second pane, so it is not $1's only surviving window", err)
	}
	if calls := kills(); len(calls) != 1 || calls[0] != "%2" {
		t.Errorf("killPane calls = %v, want exactly one call for %%2, and %%3 left alone", calls)
	}
}

var controlTreePanes = []tmux.Pane{
	{PaneID: "%1", SessionID: "$1", WindowID: "@1"},
	{PaneID: "%2", SessionID: "$1", WindowID: "@2"},
	{PaneID: "%3", SessionID: "$1", WindowID: "@3"},
}

func recordControlTree(t *testing.T, in *testutil.Inbox) {
	t.Helper()
	if err := state.Record("caller", state.Session{
		Agent: state.AgentPi, Pane: "%1", PID: os.Getpid(), Status: state.Idle,
	}); err != nil {
		t.Fatal(err)
	}
	if err := state.Record("child", state.Session{
		Agent: state.AgentPi, Pane: "%2", PID: os.Getpid(), Status: state.Idle,
		Parent: state.NewParent("caller", 0), Inbox: in.Path,
	}); err != nil {
		t.Fatal(err)
	}
	if err := state.Record("peer", state.Session{
		Agent: state.AgentPi, Pane: "%3", PID: os.Getpid(), Status: state.Idle,
		Inbox: in.Path,
	}); err != nil {
		t.Fatal(err)
	}
}

func TestInterruptRefusesNonDescendant(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, controlTreePanes)
	in := testutil.StartInbox(t, "ok\n")
	recordControlTree(t, in)

	if err := interruptSubagentCmd([]string{"peer"}); err == nil {
		t.Fatal("interruptSubagentCmd succeeded against a non-descendant, want a refusal")
	}
	if err := interruptSubagentCmd([]string{"child"}); err != nil {
		t.Fatalf("interruptSubagentCmd against an actual descendant = %v, want success", err)
	}
}

func TestStopRefusesNonDescendant(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, controlTreePanes)
	in := testutil.StartInbox(t, "ok\n")
	recordControlTree(t, in)

	if err := stopSubagentCmd([]string{"peer"}); err == nil {
		t.Fatal("stopSubagentCmd succeeded against a non-descendant, want a refusal")
	}
}

func TestInterruptHumanCallerUnrestricted(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1") // no state record for %1 itself
	withPanes(t, controlTreePanes)
	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("peer", state.Session{
		Agent: state.AgentPi, Pane: "%3", PID: os.Getpid(), Status: state.Idle,
		Inbox: in.Path,
	}); err != nil {
		t.Fatal(err)
	}

	if err := interruptSubagentCmd([]string{"peer"}); err != nil {
		t.Fatalf("interruptSubagentCmd from an unscoped human caller = %v, want success", err)
	}
}

func TestInterruptSendsEnvelope(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)

	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path,
	}); err != nil {
		t.Fatal(err)
	}

	if err := interruptSubagentCmd([]string{"target"}); err != nil {
		t.Fatalf("interruptSubagentCmd = %v, want success", err)
	}
	msgs := in.Received()
	if len(msgs) != 1 {
		t.Fatalf("server got %d messages, want 1: %q", len(msgs), msgs)
	}
	env, ok := msg.Parse([]byte(msgs[0]))
	if !ok || env.Kind != msg.KindInterrupt {
		t.Errorf("payload %q did not parse as an interrupt envelope", msgs[0])
	}
}

// TestStopEscalatesToKillingWindow: a target that acknowledges the inbox
// message but whose record never goes has its pane killed once
// stopEscalation elapses.
func TestStopEscalatesToKillingWindow(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, []tmux.Pane{
		{PaneID: "%1", SessionID: "$1", WindowID: "@1"},
		{PaneID: "%2", SessionID: "$1", WindowID: "@2"},
	})
	kills := withKillPane(t)

	testutil.Swap(t, &stopEscalation, 100*time.Millisecond)
	testutil.Swap(t, &stopPollInterval, 10*time.Millisecond)

	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path,
	}); err != nil {
		t.Fatal(err)
	}

	if err := stopSubagentCmd([]string{"target"}); err != nil {
		t.Fatalf("stopSubagentCmd = %v, want success (escalated)", err)
	}
	if calls := kills(); len(calls) != 1 || calls[0] != "%2" {
		t.Errorf("killPane calls = %v, want exactly one call for %%2", calls)
	}
}

// TestStopNoEscalationWhenTargetGoes is the negative control: a target
// whose record is removed before stopEscalation elapses is never killed.
func TestStopNoEscalationWhenTargetGoes(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, []tmux.Pane{
		{PaneID: "%1", SessionID: "$1", WindowID: "@1"},
		{PaneID: "%2", SessionID: "$1", WindowID: "@2"},
	})
	kills := withKillPane(t)

	testutil.Swap(t, &stopEscalation, 300*time.Millisecond)
	testutil.Swap(t, &stopPollInterval, 10*time.Millisecond)

	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path,
	}); err != nil {
		t.Fatal(err)
	}
	go func() {
		time.Sleep(30 * time.Millisecond)
		state.Remove("target", os.Getpid()) //nolint:errcheck
	}()

	if err := stopSubagentCmd([]string{"target"}); err != nil {
		t.Fatalf("stopSubagentCmd = %v, want success", err)
	}
	if calls := kills(); len(calls) != 0 {
		t.Errorf("killPane calls = %v, want none: the target stopped in time", calls)
	}
}

// TestStopEscalatesWhenTheTargetDoesNotAgree pins the case the escalation
// exists for: a wedged agent that never answers "ok", or refuses, or
// answers something else, still escalates rather than fails outright.
func TestStopEscalatesWhenTheTargetDoesNotAgree(t *testing.T) {
	for _, reply := range []struct{ name, answer string }{
		{"never answers", ""},
		{"refuses", "refused\n"},
		{"answers something else", "what?\n"},
	} {
		t.Run(reply.name, func(t *testing.T) {
			t.Setenv("KIDO_STATE_DIR", t.TempDir())
			t.Setenv("TMUX_PANE", "%1")
			withPanes(t, []tmux.Pane{
				{PaneID: "%1", SessionID: "$1", WindowID: "@1"},
				{PaneID: "%2", SessionID: "$1", WindowID: "@2"},
			})
			kills := withKillPane(t)

			testutil.Swap(t, &stopEscalation, 100*time.Millisecond)
			testutil.Swap(t, &stopPollInterval, 10*time.Millisecond)
			testutil.Swap(t, &msg.InboxTimeout, 200*time.Millisecond)

			in := testutil.StartInbox(t, reply.answer)
			if err := state.Record("target", state.Session{
				Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path,
			}); err != nil {
				t.Fatal(err)
			}

			if err := stopSubagentCmd([]string{"target"}); err != nil {
				t.Fatalf("stopSubagentCmd = %v, want success (escalated)", err)
			}
			if calls := kills(); len(calls) != 1 || calls[0] != "%2" {
				t.Errorf("killPane calls = %v, want exactly one call for %%2", calls)
			}
		})
	}
}

// TestStopStaleInboxStillNeedsForce: a stale socket is the same position
// as having no inbox at all, and carries the same --force requirement.
func TestStopStaleInboxStillNeedsForce(t *testing.T) {
	setup := func(t *testing.T) func() []string {
		t.Helper()
		t.Setenv("KIDO_STATE_DIR", t.TempDir())
		t.Setenv("TMUX_PANE", "%1")
		withPanes(t, []tmux.Pane{
			{PaneID: "%1", SessionID: "$1", WindowID: "@1"},
			{PaneID: "%2", SessionID: "$1", WindowID: "@2"},
		})
		kills := withKillPane(t)
		if err := state.Record("target", state.Session{
			Pane: "%2", PID: os.Getpid(), Status: state.Idle,
			Inbox: testutil.StaleSocket(t),
		}); err != nil {
			t.Fatal(err)
		}
		return kills
	}

	t.Run("without --force", func(t *testing.T) {
		kills := setup(t)
		if err := stopSubagentCmd([]string{"target"}); err == nil {
			t.Fatal("stopSubagentCmd succeeded, want a refusal: the inbox is stale and --force was not given")
		}
		if calls := kills(); len(calls) != 0 {
			t.Errorf("killPane calls = %v, want none without --force", calls)
		}
	})
	t.Run("with --force", func(t *testing.T) {
		kills := setup(t)
		if err := stopSubagentCmd([]string{"--force", "target"}); err != nil {
			t.Fatalf("stopSubagentCmd = %v, want success", err)
		}
		if calls := kills(); len(calls) != 1 || calls[0] != "%2" {
			t.Errorf("killPane calls = %v, want exactly one call for %%2", calls)
		}
	})
}

// TestControlErrorsAreNotDoublePrefixed pins that these commands leave
// the "kido <verb>: " prefix to dispatch, which adds it to every error
// it prints.
func TestControlErrorsAreNotDoublePrefixed(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, controlTreePanes)
	in := testutil.StartInbox(t, "ok\n")
	recordControlTree(t, in)

	for _, args := range [][]string{{"peer"}, {"caller"}} {
		for verb, run := range map[string]func([]string) error{"interrupt_subagent": interruptSubagentCmd, "stop_subagent": stopSubagentCmd} {
			err := run(args)
			if err == nil {
				t.Fatalf("%s %v succeeded, want a refusal", verb, args)
			}
			if strings.Contains(err.Error(), "kido "+verb+":") {
				t.Errorf("%s %v error = %q, want no \"kido %s:\" prefix (dispatch adds it)", verb, args, err, verb)
			}
		}
	}
}

func TestInterruptRefusesSelf(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	if err := state.Record("me", state.Session{Pane: "%1", PID: os.Getpid(), Status: state.Idle, Title: "Self"}); err != nil {
		t.Fatal(err)
	}
	if err := interruptSubagentCmd([]string{"Self"}); err == nil {
		t.Fatal("interruptSubagentCmd against self succeeded, want a refusal")
	}
}

// TestInterruptRefusedAgainstInboxlessAgent: unlike stop, interrupt has
// no --force degrade at all.
func TestInterruptRefusedAgainstInboxlessAgent(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	kills := withKillPane(t)

	if err := state.Record("target", state.Session{Pane: "%2", PID: os.Getpid(), Status: state.Idle}); err != nil {
		t.Fatal(err)
	}
	if err := interruptSubagentCmd([]string{"target"}); err == nil {
		t.Fatal("interruptSubagentCmd succeeded, want a refusal: target has no inbox and interrupt has no --force degrade")
	}
	if calls := kills(); len(calls) != 0 {
		t.Errorf("killPane calls = %v, want none: interrupt never kills anything", calls)
	}
}

// TestStopRefusedLeavesNoOutcome pins the ordering in stopSubagentCmd:
// the Stopped outcome goes in only once the stop request is actually
// away, since subrun.RecordOutcome writes once and for all (O_EXCL).
// Every refusal stopSubagentCmd has is covered here.
func TestStopRefusedLeavesNoOutcome(t *testing.T) {
	setup := func(t *testing.T, runID string, panes []tmux.Pane, target state.Session) {
		t.Helper()
		t.Setenv("KIDO_STATE_DIR", t.TempDir())
		t.Setenv("TMUX_PANE", "%1")
		withPanes(t, panes)
		withKillPane(t)
		if err := subrun.Create(subrun.ID(runID), "do the thing"); err != nil {
			t.Fatal(err)
		}
		if err := subrun.WriteMeta(subrun.Meta{ID: subrun.ID(runID), PID: os.Getpid()}); err != nil {
			t.Fatal(err)
		}
		if err := state.Record(runID, target); err != nil {
			t.Fatal(err)
		}
	}
	noOutcome := func(t *testing.T, runID string) {
		t.Helper()
		if o, ok, err := subrun.ReadOutcome(subrun.ID(runID)); ok || err != nil {
			t.Errorf("ReadOutcome = %+v, %v, %v; a refused stop must leave the run with no outcome at all", o, ok, err)
		}
	}

	twoWindows := []tmux.Pane{
		{PaneID: "%1", SessionID: "$1", WindowID: "@1"},
		{PaneID: "%2", SessionID: "$1", WindowID: "@2"},
	}

	t.Run("no inbox, no --force", func(t *testing.T) {
		setup(t, "run-noinbox", twoWindows, state.Session{Pane: "%2", PID: os.Getpid(), Status: state.Idle})
		if err := stopSubagentCmd([]string{"run-noinbox"}); err == nil {
			t.Fatal("stopSubagentCmd succeeded, want the no-inbox refusal")
		}
		noOutcome(t, "run-noinbox")
	})

	t.Run("stale inbox, no --force", func(t *testing.T) {
		setup(t, "run-stale", twoWindows, state.Session{
			Pane: "%2", PID: os.Getpid(), Status: state.Idle,
			Inbox: testutil.StaleSocket(t),
		})
		if err := stopSubagentCmd([]string{"run-stale"}); err == nil {
			t.Fatal("stopSubagentCmd succeeded, want the stale-inbox refusal")
		}
		noOutcome(t, "run-stale")
	})

	t.Run("not the caller's descendant", func(t *testing.T) {
		in := testutil.StartInbox(t, "ok\n")
		setup(t, "run-peer", controlTreePanes, state.Session{
			Agent: state.AgentPi, Pane: "%3", PID: os.Getpid(), Status: state.Idle,
			Inbox: in.Path,
		})
		if err := state.Record("caller", state.Session{
			Agent: state.AgentPi, Pane: "%1", PID: os.Getpid(), Status: state.Idle,
		}); err != nil {
			t.Fatal(err)
		}
		if err := stopSubagentCmd([]string{"run-peer"}); err == nil {
			t.Fatal("stopSubagentCmd succeeded against a non-descendant, want a refusal")
		}
		noOutcome(t, "run-peer")
	})

	// Checked against killRunPane directly: stopSubagentCmd's own scope
	// rule would turn this layout away first, with a different error.
	t.Run("the session's last window", func(t *testing.T) {
		setup(t, "run-last", []tmux.Pane{
			{PaneID: "%1", SessionID: "$2", WindowID: "@9"},
			{PaneID: "%2", SessionID: "$1", WindowID: "@1"},
		}, state.Session{Pane: "%2", PID: os.Getpid(), Status: state.Idle})
		target := state.Session{ID: "run-last", Pane: "%2"}
		if _, err := killRunPane(target.Pane, func() { recordStopped(target) }); err == nil {
			t.Fatal("killRunPane succeeded, want the last-window refusal")
		}
		noOutcome(t, "run-last")
	})
}

func TestControlUsage(t *testing.T) {
	if err := interruptSubagentCmd(nil); err == nil || !strings.Contains(err.Error(), "usage") {
		t.Errorf("interruptSubagentCmd(nil) = %v, want a usage error", err)
	}
	if err := stopSubagentCmd(nil); err == nil || !strings.Contains(err.Error(), "usage") {
		t.Errorf("stopSubagentCmd(nil) = %v, want a usage error", err)
	}
}

// steerTreePanes and recordSteerTree give the caller an ancestor of its
// own and a descendant two deep, so a parent-only scope rule would fail.
var steerTreePanes = []tmux.Pane{
	{PaneID: "%1", SessionID: "$1", WindowID: "@1"},
	{PaneID: "%2", SessionID: "$1", WindowID: "@2"},
	{PaneID: "%3", SessionID: "$1", WindowID: "@3"},
	{PaneID: "%4", SessionID: "$1", WindowID: "@4"},
	{PaneID: "%5", SessionID: "$1", WindowID: "@5"},
}

func recordSteerTree(t *testing.T, in *testutil.Inbox) {
	t.Helper()
	rows := []struct {
		id, pane, parent string
	}{
		{"root", "%4", ""},
		{"caller", "%1", "root"},
		{"child", "%2", "caller"},
		{"grandchild", "%5", "child"},
		{"peer", "%3", ""},
	}
	for _, r := range rows {
		s := state.Session{
			Agent: state.AgentPi, Pane: r.pane, PID: os.Getpid(), Status: state.Idle,
			Parent: state.NewParent(r.parent, 0), Inbox: in.Path,
		}
		if err := state.Record(r.id, s); err != nil {
			t.Fatal(err)
		}
	}
}

// TestSteerReachesDescendants checks that steer_subagent delivers a v1
// "steer" envelope, and reaches a grandchild as well as a child.
func TestSteerReachesDescendants(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, steerTreePanes)
	in := testutil.StartInbox(t, "ok\n")
	recordSteerTree(t, in)

	for _, to := range []string{"child", "grandchild"} {
		if code := steerSubagentCmd([]string{"--", to}, strings.NewReader("stop and do X instead")); code != 0 {
			t.Fatalf("steer_subagent %s = %d, want 0", to, code)
		}
	}
	msgs := in.Received()
	if len(msgs) != 2 {
		t.Fatalf("inbox got %d envelopes, want 2: %q", len(msgs), msgs)
	}
	for _, raw := range msgs {
		env, ok := msg.Parse([]byte(raw))
		if !ok {
			t.Fatalf("payload %q did not parse as a v1 envelope", raw)
		}
		if env.Kind != msg.KindSteer {
			t.Errorf("envelope kind = %q, want %q: a steer delivered as any other kind is queued, not steered", env.Kind, msg.KindSteer)
		}
		if env.Text != "stop and do X instead" {
			t.Errorf("envelope text = %q, want the message verbatim", env.Text)
		}
	}
}

// TestSteerRefusesNonDescendants: a peer, an ancestor and the caller
// itself are all refused, and nothing is sent to any of them.
func TestSteerRefusesNonDescendants(t *testing.T) {
	for _, to := range []string{"peer", "root", "caller"} {
		t.Run(to, func(t *testing.T) {
			t.Setenv("KIDO_STATE_DIR", t.TempDir())
			t.Setenv("TMUX_PANE", "%1")
			withPanes(t, steerTreePanes)
			pastes := withSendPrompt(t, errors.New("sendPrompt must not be called"))
			in := testutil.StartInbox(t, "ok\n")
			recordSteerTree(t, in)

			if code := steerSubagentCmd([]string{"--", to}, strings.NewReader("do something else")); code != 1 {
				t.Fatalf("steer_subagent %s = %d, want 1", to, code)
			}
			if msgs := in.Received(); len(msgs) != 0 {
				t.Errorf("inbox got %q, want nothing sent to a non-descendant", msgs)
			}
			if calls := pastes(); len(calls) != 0 {
				t.Errorf("sendPrompt calls = %v, want none: a steer has no paste fallback either", calls)
			}
		})
	}
}

func TestSteerUsage(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, steerTreePanes)
	in := testutil.StartInbox(t, "ok\n")
	recordSteerTree(t, in)

	if code := steerSubagentCmd(nil, strings.NewReader("x")); code != 1 {
		t.Error("steer_subagent with no target = 0, want 1")
	}
	if code := steerSubagentCmd([]string{"child", "grandchild"}, strings.NewReader("x")); code != 1 {
		t.Error("steer_subagent with two targets = 0, want 1")
	}
	if code := steerSubagentCmd([]string{"--", "child"}, strings.NewReader("")); code != 1 {
		t.Error("steer_subagent with empty stdin = 0, want 1")
	}
	if msgs := in.Received(); len(msgs) != 0 {
		t.Errorf("inbox got %q, want nothing sent", msgs)
	}
}

func bashRunUnder(t *testing.T, name, parent string, pid int) subrun.Meta {
	t.Helper()
	meta := subrun.Meta{ID: startAsyncRun(t, name, parent, "sleep", "600"), Name: name, Kind: subrun.KindBash,
		ParentSession: parent, Pane: "%2", PID: pid, StartedAt: time.Now()}
	if err := subrun.WriteMeta(meta); err != nil {
		t.Fatal(err)
	}
	return meta
}

func withStopEscalation(t *testing.T, d time.Duration) {
	t.Helper()
	testutil.Swap(t, &stopEscalation, d)
}

// TestStopBashRunReportsWhenTheWrapperCannot: a deliberate stop is an
// ending too, and when the wrapper is not there to describe it (the
// run's pid belongs to nothing) the stop must.
func TestStopBashRunReportsWhenTheWrapperCannot(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	in := noticeParent(t, "root-sess")
	killed := withKillPane(t)
	meta := bashRunUnder(t, "doomed", "root-sess", testutil.DeadPID(t))

	capture(t, &os.Stdout, func() {
		if err := stopSubagentCmd([]string{"--force", "doomed"}); err != nil {
			t.Fatal(err)
		}
	})

	got := envelopes(t, in)
	if len(got) != 1 {
		t.Fatalf("parent received %d envelopes, want exactly 1: %+v", len(got), got)
	}
	if got[0].From.Name != "doomed" {
		t.Errorf("notice is from %+v, want the run's name", got[0].From)
	}
	if !strings.Contains(got[0].Text, "stopped") {
		t.Errorf("notice text = %q, want it to say the run was stopped", got[0].Text)
	}
	o, ok, _ := subrun.ReadOutcome(meta.ID)
	if !ok || o.Result != subrun.Stopped || o.Text != stoppedText {
		t.Errorf("outcome = %+v (recorded %v), want %q/%q", o, ok, subrun.Stopped, stoppedText)
	}
	if calls := killed(); len(calls) != 1 || calls[0] != "%2" {
		t.Errorf("killPane calls = %v, want the run's own pane", calls)
	}
}

// TestStopBashRunLeavesTheWrapperToReportIfItCan is the negative control
// for the test above: a wrapper that is still there reports the ending
// itself, and a stop must not tell a second story about it.
func TestStopBashRunLeavesTheWrapperToReportIfItCan(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	in := noticeParent(t, "root-sess")
	killed := withKillPane(t)
	withStopEscalation(t, 2*time.Second)

	sleep := exec.Command("sleep", "30")
	if err := sleep.Start(); err != nil {
		t.Fatal(err)
	}
	defer sleep.Process.Kill() //nolint:errcheck // best effort cleanup
	meta := bashRunUnder(t, "polite", "root-sess", sleep.Process.Pid)
	go func() {
		time.Sleep(150 * time.Millisecond)
		subrun.RecordOutcome(meta.ID, subrun.Outcome{ //nolint:errcheck // the assertion below reads it back
			Result: subrun.Failed, Text: "killed by terminated", At: time.Now()})
	}()

	out := capture(t, &os.Stdout, func() {
		if err := stopSubagentCmd([]string{"--force", "polite"}); err != nil {
			t.Fatal(err)
		}
	})
	if !strings.Contains(out, "wrapper reported") {
		t.Errorf("kido stop_subagent said %q, want it to say the wrapper reported the ending", out)
	}
	if got := in.Received(); len(got) != 0 {
		t.Errorf("parent received %q, want nothing: the wrapper's own notice is the one ending this run gets", got)
	}
	if o, _, _ := subrun.ReadOutcome(meta.ID); o.Text != "killed by terminated" {
		t.Errorf("outcome = %+v, want the wrapper's own story to stand", o)
	}
	if calls := killed(); len(calls) != 0 {
		t.Errorf("killPane calls = %v, want none: the run ended when it was asked to", calls)
	}
}

// TestStopBashRunStillNeedsForce: a bash run has no inbox, so stopping
// it degrades straight to killing something, gated by --force like any
// other inbox-less target. Carried by the absences: nothing killed, no
// outcome recorded, nothing sent.
func TestStopBashRunStillNeedsForce(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	in := noticeParent(t, "root-sess")
	killed := withKillPane(t)
	meta := bashRunUnder(t, "doomed", "root-sess", testutil.DeadPID(t))

	err := stopSubagentCmd([]string{"doomed"})
	if err == nil {
		t.Fatal("stopSubagentCmd on a bash run without --force succeeded, want the inbox-less refusal")
	}
	if !strings.Contains(err.Error(), "--force") {
		t.Errorf("refusal = %v, want it to name --force", err)
	}
	if calls := killed(); len(calls) != 0 {
		t.Errorf("killPane calls = %v, want none after a refusal", calls)
	}
	if o, ok, _ := subrun.ReadOutcome(meta.ID); ok {
		t.Errorf("a refused stop recorded %+v, want nothing", o)
	}
	if got := in.Received(); len(got) != 0 {
		t.Errorf("a refused stop sent %q, want nothing", got)
	}
}

// TestStopBashRunRefusesANonDescendant: a bash run writes no state
// record, so it is reached by the parent session recorded in its meta.
func TestStopBashRunRefusesANonDescendant(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, controlTreePanes)
	in := testutil.StartInbox(t, "ok\n")
	recordControlTree(t, in)
	withKillPane(t)

	stranger := bashRunUnder(t, "stranger", "peer", testutil.DeadPID(t))
	if err := stopSubagentCmd([]string{"--force", "stranger"}); err == nil {
		t.Fatal("stopSubagentCmd reached a run under an unrelated agent, want a refusal")
	}
	if o, ok, _ := subrun.ReadOutcome(stranger.ID); ok {
		t.Errorf("a refused stop recorded %+v, want nothing", o)
	}

	mine := bashRunUnder(t, "mine", "child", testutil.DeadPID(t))
	capture(t, &os.Stdout, func() {
		if err := stopSubagentCmd([]string{"--force", "mine"}); err != nil {
			t.Fatalf("stopSubagentCmd on a run started by this agent's own child = %v, want success", err)
		}
	})
	if o, ok, _ := subrun.ReadOutcome(mine.ID); !ok || o.Result != subrun.Stopped {
		t.Errorf("outcome = %+v (recorded %v), want it stopped", o, ok)
	}
}

// TestStopIgnoresAFinishedBashRun: only a run with no outcome yet is
// matched by name, so a finished run cannot shadow a live agent sharing
// its name.
func TestStopIgnoresAFinishedBashRun(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, controlTreePanes)
	in := testutil.StartInbox(t, "ok\n")
	recordControlTree(t, in)

	done := bashRunUnder(t, "child", "caller", testutil.DeadPID(t))
	if err := subrun.RecordOutcome(done.ID, subrun.Outcome{Result: subrun.Completed, At: time.Now()}); err != nil {
		t.Fatal(err)
	}
	withKillPane(t)
	withStopEscalation(t, 100*time.Millisecond)
	capture(t, &os.Stdout, func() {
		if err := stopSubagentCmd([]string{"child"}); err != nil {
			t.Fatalf("stopSubagentCmd = %v, want the agent named \"child\" to be stopped over its inbox", err)
		}
	})
	got := in.Received()
	if len(got) != 1 {
		t.Fatalf("agent inbox received %q, want the stop envelope", got)
	}
	if env, ok := msg.Parse([]byte(got[0])); !ok || env.Kind != msg.KindStop {
		t.Errorf("agent inbox received %q, want a stop envelope", got[0])
	}
}
