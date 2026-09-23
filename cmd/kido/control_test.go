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

// withKillPane replaces killPane with a fake that records its calls
// instead of talking to a real tmux server, the same pattern
// withSendPrompt (message_test.go) uses for sendPrompt - what stopSubagentCmd's
// degrade and escalation actually call (see cmd/kido/control.go's
// killTargetPane).
func withKillPane(t *testing.T) func() []string {
	t.Helper()
	prev := killPane
	var calls []string
	killPane = func(id string) error {
		calls = append(calls, id)
		return nil
	}
	t.Cleanup(func() { killPane = prev })
	return func() []string { return calls }
}

// TestStopNoForceRefusedAgainstInboxlessAgent checks the degrade rule: an
// agent with no inbox at all cannot be asked to stop, so stopping one
// must be refused unless --force says the caller means it, and must not
// kill anything either way without it.
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

// TestStopForceKillsInboxlessAgent is the positive control: --force
// degrades straight to killing the target's window.
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

// TestStopRefusesToKillASessionsOnlyWindow: a target in a different tmux
// session from the caller is refused by resolveTarget's session scope,
// before killTargetPane's last-pane guard ever runs. The layout below is
// the one that guard is about, but this test does not reach it (see
// TestStopRefusedLeavesNoOutcome's "the session's last window" subtest,
// which calls killTargetPane directly); it pins that a cross-session
// target is refused and --force does not buy it.
func TestStopRefusesToKillASessionsOnlyWindow(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	// The caller sits in a separate session ($2) so it cannot also be
	// read as targeting itself; $1's only window (@1) holds only the
	// target's own pane.
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

// TestStopKillsOneOfTwoPanesInAWindow: a window with a bystander pane
// beside the target. Only the target's own pane may go; killing the
// window would take the bystander with it.
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

// controlTreePanes and controlTreeStates set up a caller ("%1", session
// "caller") who is the parent of "%2" (a child) and unrelated to "%3" (a
// peer) - the shape both interrupt and stop's descendant-scope refusal
// tests need.
var controlTreePanes = []tmux.Pane{
	{PaneID: "%1", SessionID: "$1", WindowID: "@1"},
	{PaneID: "%2", SessionID: "$1", WindowID: "@2"},
	{PaneID: "%3", SessionID: "$1", WindowID: "@3"},
}

func recordControlTree(t *testing.T, in *testutil.Inbox) {
	t.Helper()
	if err := state.Record("caller", state.Session{
		Agent: state.AgentPi, Pane: "%1", PID: os.Getpid(), Status: state.Idle, Instance: "caller-i",
	}); err != nil {
		t.Fatal(err)
	}
	if err := state.Record("child", state.Session{
		Agent: state.AgentPi, Pane: "%2", PID: os.Getpid(), Status: state.Idle,
		Instance: "child-i", ParentInstance: "caller-i", Inbox: in.Path, Protocol: msg.V1,
	}); err != nil {
		t.Fatal(err)
	}
	if err := state.Record("peer", state.Session{
		Agent: state.AgentPi, Pane: "%3", PID: os.Getpid(), Status: state.Idle,
		Instance: "peer-i", Inbox: in.Path, Protocol: msg.V1,
	}); err != nil {
		t.Fatal(err)
	}
}

// TestInterruptRefusesNonDescendant and TestStopRefusesNonDescendant check
// the shared scope rule: an agent caller may reach its own descendants
// only, so a confused peer cannot interrupt or stop something unrelated
// to it. Reaching its actual child succeeds.
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

// TestInterruptHumanCallerUnrestricted checks that a caller with no state
// record of its own (a human typing at the CLI, per AGENTS.md's Trust
// section) is not scoped to descendants at all.
func TestInterruptHumanCallerUnrestricted(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1") // no state record for %1 itself
	withPanes(t, controlTreePanes)
	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("peer", state.Session{
		Agent: state.AgentPi, Pane: "%3", PID: os.Getpid(), Status: state.Idle,
		Inbox: in.Path, Protocol: msg.V1,
	}); err != nil {
		t.Fatal(err)
	}

	if err := interruptSubagentCmd([]string{"peer"}); err != nil {
		t.Fatalf("interruptSubagentCmd from an unscoped human caller = %v, want success", err)
	}
}

// TestInterruptSendsEnvelope checks that a successful interrupt puts a v1
// "interrupt" envelope on the target's inbox.
func TestInterruptSendsEnvelope(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)

	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path, Protocol: msg.V1,
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

// TestStopEscalatesToKillingWindow checks the escalation stopSubagentCmd's own
// doc describes: a target that acknowledges the inbox message ("ok\n")
// but whose record never goes (nothing ever calls state.Remove or lets
// its pid die, exactly as a wedged extension would leave it) has its
// pane killed once stopEscalation elapses.
func TestStopEscalatesToKillingWindow(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, []tmux.Pane{
		{PaneID: "%1", SessionID: "$1", WindowID: "@1"},
		{PaneID: "%2", SessionID: "$1", WindowID: "@2"},
	})
	kills := withKillPane(t)

	savedEscalation, savedPoll := stopEscalation, stopPollInterval
	stopEscalation = 100 * time.Millisecond
	stopPollInterval = 10 * time.Millisecond
	t.Cleanup(func() { stopEscalation, stopPollInterval = savedEscalation, savedPoll })

	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path, Protocol: msg.V1,
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
// whose record is removed before stopEscalation elapses (a healthy
// session_shutdown, in reality) is never killed.
func TestStopNoEscalationWhenTargetGoes(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, []tmux.Pane{
		{PaneID: "%1", SessionID: "$1", WindowID: "@1"},
		{PaneID: "%2", SessionID: "$1", WindowID: "@2"},
	})
	kills := withKillPane(t)

	savedEscalation, savedPoll := stopEscalation, stopPollInterval
	stopEscalation = 300 * time.Millisecond
	stopPollInterval = 10 * time.Millisecond
	t.Cleanup(func() { stopEscalation, stopPollInterval = savedEscalation, savedPoll })

	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path, Protocol: msg.V1,
	}); err != nil {
		t.Fatal(err)
	}
	go func() {
		time.Sleep(30 * time.Millisecond)
		state.Remove("target") //nolint:errcheck
	}()

	if err := stopSubagentCmd([]string{"target"}); err != nil {
		t.Fatalf("stopSubagentCmd = %v, want success", err)
	}
	if calls := kills(); len(calls) != 0 {
		t.Errorf("killPane calls = %v, want none: the target stopped in time", calls)
	}
}

// TestStopEscalatesWhenTheTargetDoesNotAgree pins the case the escalation
// exists for: a wedged agent does not answer "ok". It holds the
// connection open until the deadline, or answers something else, or its
// own scope check refuses, and every one of those is a reason to
// escalate rather than give up. Returning the send error instead leaves
// kido stop_subagent failing outright, with the window intact, exactly when it is
// needed most; --force does not help, because that flag is about having
// no inbox, not about an inbox that answered badly.
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

			savedEscalation, savedPoll, savedInbox := stopEscalation, stopPollInterval, inboxTimeout
			stopEscalation, stopPollInterval, inboxTimeout = 100*time.Millisecond, 10*time.Millisecond, 200*time.Millisecond
			t.Cleanup(func() {
				stopEscalation, stopPollInterval, inboxTimeout = savedEscalation, savedPoll, savedInbox
			})

			in := testutil.StartInbox(t, reply.answer)
			if err := state.Record("target", state.Session{
				Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path, Protocol: msg.V1,
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

// TestStopStaleInboxStillNeedsForce is the one send failure that is not an
// escalation: a recorded socket nobody is listening on means nothing was
// asked and nothing could be, which is the same position as having no
// inbox at all and carries the same --force requirement.
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
			Inbox: testutil.StaleSocket(t), Protocol: msg.V1,
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

// TestControlErrorsAreNotDoublePrefixed pins that these commands leave the
// "kido <verb>: " prefix to dispatch (main.go), which adds it to every
// error it prints. Saying it here too printed "kido stop_subagent: kido stop_subagent: ..."
// at the terminal.
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

// TestInterruptRefusesSelf and TestStopRefusesSelf pin that a caller
// cannot target its own pane, matching kido message_agent's own rule.
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
// no --force degrade at all, so an agent with no inbox to carry the
// request is simply refused, with nothing killed.
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

// TestStopRefusedLeavesNoOutcome pins the ordering in stopSubagentCmd: the Stopped
// outcome goes in only once the stop request is actually away, because
// subrun.RecordOutcome writes once and for all (O_EXCL), so an outcome
// written on a path that then refuses marks a run that is still running
// as stopped forever. Every refusal stop has is covered, and moving
// recordStopped back above the guards fails all but the last of them.
func TestStopRefusedLeavesNoOutcome(t *testing.T) {
	// A run record whose id is the target's session id, which is what makes
	// target.ID a run id at all (see recordStopped).
	setup := func(t *testing.T, runID string, panes []tmux.Pane, target state.Session) {
		t.Helper()
		t.Setenv("KIDO_STATE_DIR", t.TempDir())
		t.Setenv("TMUX_PANE", "%1")
		withPanes(t, panes)
		withKillPane(t)
		if err := subrun.Create(runID, "do the thing"); err != nil {
			t.Fatal(err)
		}
		if err := subrun.WriteMeta(subrun.Meta{ID: runID, PID: os.Getpid()}); err != nil {
			t.Fatal(err)
		}
		if err := state.Record(runID, target); err != nil {
			t.Fatal(err)
		}
	}
	noOutcome := func(t *testing.T, runID string) {
		t.Helper()
		if o, ok, err := subrun.ReadOutcome(runID); ok || err != nil {
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
			Inbox: testutil.StaleSocket(t), Protocol: msg.V1,
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
			Instance: "peer-i", Inbox: in.Path, Protocol: msg.V1,
		})
		// The caller needs a record of its own for the descendant scope rule
		// to apply at all (controlTarget).
		if err := state.Record("caller", state.Session{
			Agent: state.AgentPi, Pane: "%1", PID: os.Getpid(), Status: state.Idle, Instance: "caller-i",
		}); err != nil {
			t.Fatal(err)
		}
		if err := stopSubagentCmd([]string{"run-peer"}); err == nil {
			t.Fatal("stopSubagentCmd succeeded against a non-descendant, want a refusal")
		}
		noOutcome(t, "run-peer")
	})

	// The session's-last-window refusal is checked against killTargetPane
	// directly, not through stopSubagentCmd: a caller may only stop something in
	// its own tmux session (resolveTarget), and a session holding the
	// caller's pane too always has a second pane for the guard to spare -
	// so the layout the guard is about is one stopSubagentCmd's own scope rule
	// turns away first, with a different error. TestStopRefusesToKillA
	// SessionsOnlyWindow above takes that earlier refusal for the same
	// reason.
	t.Run("the session's last window", func(t *testing.T) {
		setup(t, "run-last", []tmux.Pane{
			{PaneID: "%1", SessionID: "$2", WindowID: "@9"},
			{PaneID: "%2", SessionID: "$1", WindowID: "@1"},
		}, state.Session{Pane: "%2", PID: os.Getpid(), Status: state.Idle})
		if err := killTargetPane(state.Session{ID: "run-last", Pane: "%2"}); err == nil {
			t.Fatal("killTargetPane succeeded, want the last-window refusal")
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

// steerTreePanes and recordSteerTree are the tree steer_subagent's scope
// rule needs and controlTreePanes cannot express: a caller with an
// ancestor of its own, and a descendant two deep. %1 caller is root's
// child and child's parent; %5 is child's child, so it is the caller's
// grandchild and must be reachable - nesting goes two deep, and a
// parent-only rule would refuse it.
var steerTreePanes = []tmux.Pane{
	{PaneID: "%1", SessionID: "$1", WindowID: "@1"},
	{PaneID: "%2", SessionID: "$1", WindowID: "@2"},
	{PaneID: "%3", SessionID: "$1", WindowID: "@3"},
	{PaneID: "%4", SessionID: "$1", WindowID: "@4"},
	{PaneID: "%5", SessionID: "$1", WindowID: "@5"},
}

// recordSteerTree records that tree, every reachable session sharing one
// inbox: which of them received something is what the refusals are about,
// and a refusal must leave the socket silent whoever it was aimed at.
func recordSteerTree(t *testing.T, in *testutil.Inbox) {
	t.Helper()
	rows := []struct {
		id, pane, instance, parent string
	}{
		{"root", "%4", "root-i", ""},
		{"caller", "%1", "caller-i", "root-i"},
		{"child", "%2", "child-i", "caller-i"},
		{"grandchild", "%5", "grandchild-i", "child-i"},
		{"peer", "%3", "peer-i", ""},
	}
	for _, r := range rows {
		s := state.Session{
			Agent: state.AgentPi, Pane: r.pane, PID: os.Getpid(), Status: state.Idle,
			Instance: r.instance, ParentInstance: r.parent, Inbox: in.Path, Protocol: msg.V1,
		}
		if err := state.Record(r.id, s); err != nil {
			t.Fatal(err)
		}
	}
}

// TestSteerReachesDescendants checks that steer_subagent delivers a v1
// "steer" envelope - the kind, since the kind is the whole point: it is
// what makes the receiving extension hand the text to its model inside
// the running turn instead of queueing it (docs/design.md, "Steer and
// followUp") - and that it reaches a grandchild as well as a child.
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

// TestSteerRefusesNonDescendants pins the rule the _subagent suffix
// carries: a peer, an ancestor and the caller itself are all refused, and
// nothing is sent to any of them. Steering redirects work already under
// way, the same authority interrupt_subagent needs, so the two agree
// about who may use it (cmd/kido/control.go, descendantTarget).
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

// TestSteerUsage: no target, two targets, and empty text are all refused
// before anything is resolved or delivered.
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

// bashRunUnder writes a run `kido async_bash` would have created under
// parent, still going: no outcome, a pane of its own, and a pid the
// caller chooses so a test can decide whether its wrapper is still there
// to be signalled.
func bashRunUnder(t *testing.T, name, parent string, pid int) subrun.Meta {
	t.Helper()
	meta := subrun.Meta{ID: startAsyncRun(t, "sleep", "600"), Name: name, Kind: subrun.KindBash,
		ParentInstance: parent, Pane: "%2", Window: "@2", PID: pid, StartedAt: time.Now()}
	if err := subrun.WriteMeta(meta); err != nil {
		t.Fatal(err)
	}
	return meta
}

// withStopEscalation shortens the grace stopBashRun gives a wrapper to
// report for itself. The package variable rather than the environment,
// because it is read once at init and this is the only process reading
// it here.
func withStopEscalation(t *testing.T, d time.Duration) {
	t.Helper()
	prev := stopEscalation
	stopEscalation = d
	t.Cleanup(func() { stopEscalation = prev })
}

// TestStopBashRunReportsWhenTheWrapperCannot is the other half of the
// exactly-once invariant: a deliberate stop is an ending too, and when
// the wrapper is not there to describe it the stop must. The run's pid
// here belongs to nothing, which is the SIGKILLed-wrapper case and the
// reason the grace is skipped rather than waited out - there is nobody
// left who could report.
//
// The outcome text is the stop's own, distinct from the wrapper's "exit
// status N" and from a sweep's, so a parent can tell which observer
// found the ending.
func TestStopBashRunReportsWhenTheWrapperCannot(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	in := noticeParent(t, "root-inst")
	killed := withKillPane(t)
	meta := bashRunUnder(t, "doomed", "root-inst", deadPID(t))

	captureStdout(t, func() {
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
// for the test above, and the reason the stop signals before it speaks:
// a wrapper that is still there reports the ending itself, with the exit
// status and the output tail a stop can only guess at, and having asked
// for the stop is no licence to tell a second story about it. The
// outcome write is what arbitrates, exactly as it does for a sweep.
func TestStopBashRunLeavesTheWrapperToReportIfItCan(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	in := noticeParent(t, "root-inst")
	killed := withKillPane(t)
	withStopEscalation(t, 2*time.Second)

	// A real process to signal, so the wait is entered at all; the
	// goroutine below stands in for the wrapper it would be, recording
	// the ending inside the grace.
	sleep := exec.Command("sleep", "30")
	if err := sleep.Start(); err != nil {
		t.Fatal(err)
	}
	defer sleep.Process.Kill() //nolint:errcheck // best effort cleanup
	meta := bashRunUnder(t, "polite", "root-inst", sleep.Process.Pid)
	go func() {
		time.Sleep(150 * time.Millisecond)
		subrun.RecordOutcome(meta.ID, subrun.Outcome{ //nolint:errcheck // the assertion below reads it back
			Result: subrun.Failed, Text: "killed by terminated", At: time.Now()})
	}()

	out := captureStdout(t, func() {
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

// TestStopBashRunStillNeedsForce pins that nothing here relaxed the
// refusal every inbox-less target is held to. A bash run has no inbox to
// ask nicely over, so stopping it degrades straight to killing
// something, which is what --force means; whether that gate is right for
// a build rather than an agent is a separate question and a separate
// change to a refusal.
//
// The assertions that carry it are the absences: nothing killed, no
// outcome recorded, nothing sent. A refusal that returned an error and
// still stopped the run would satisfy the first one alone.
func TestStopBashRunStillNeedsForce(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	in := noticeParent(t, "root-inst")
	killed := withKillPane(t)
	meta := bashRunUnder(t, "doomed", "root-inst", deadPID(t))

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

// TestStopBashRunRefusesANonDescendant: a run is reached by the same
// scope rule as an agent, applied to the only parent edge it has - the
// instance `kido async_bash` recorded in its meta, since a bash run
// writes no state record for descendantTarget to walk.
func TestStopBashRunRefusesANonDescendant(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, controlTreePanes)
	in := testutil.StartInbox(t, "ok\n")
	recordControlTree(t, in)
	withKillPane(t)

	// caller-i is the caller's own instance and child-i its child's, so a
	// run under peer-i is nobody's business here.
	stranger := bashRunUnder(t, "stranger", "peer-i", deadPID(t))
	if err := stopSubagentCmd([]string{"--force", "stranger"}); err == nil {
		t.Fatal("stopSubagentCmd reached a run under an unrelated agent, want a refusal")
	}
	if o, ok, _ := subrun.ReadOutcome(stranger.ID); ok {
		t.Errorf("a refused stop recorded %+v, want nothing", o)
	}

	// The descendant half, so the refusal above is a rule about scope and
	// not about bash runs being unreachable: a run under the caller's own
	// child is a descendant.
	mine := bashRunUnder(t, "mine", "child-i", deadPID(t))
	captureStdout(t, func() {
		if err := stopSubagentCmd([]string{"--force", "mine"}); err != nil {
			t.Fatalf("stopSubagentCmd on a run started by this agent's own child = %v, want success", err)
		}
	})
	if o, ok, _ := subrun.ReadOutcome(mine.ID); !ok || o.Result != subrun.Stopped {
		t.Errorf("outcome = %+v (recorded %v), want it stopped", o, ok)
	}
}

// TestStopIgnoresAFinishedBashRun: only a run with no outcome yet is
// matched by name, so a finished run cannot shadow a live agent that
// happens to share its name - and stop goes on meaning what it meant.
func TestStopIgnoresAFinishedBashRun(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, controlTreePanes)
	in := testutil.StartInbox(t, "ok\n")
	recordControlTree(t, in)

	done := bashRunUnder(t, "child", "caller-i", deadPID(t))
	if err := subrun.RecordOutcome(done.ID, subrun.Outcome{Result: subrun.Completed, At: time.Now()}); err != nil {
		t.Fatal(err)
	}
	withKillPane(t)
	withStopEscalation(t, 100*time.Millisecond)
	captureStdout(t, func() {
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
