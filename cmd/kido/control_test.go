package main

import (
	"os"
	"strings"
	"testing"
	"time"

	"kido/internal/msg"
	"kido/internal/state"
	"kido/internal/testutil"
	"kido/internal/tmux"
)

// withKillPane replaces killPane with a fake that records its calls
// instead of talking to a real tmux server, the same pattern
// withSendPrompt (message_test.go) uses for sendPrompt - what stopCmd's
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
	if err := stopCmd([]string{"target"}); err == nil {
		t.Fatal("stopCmd succeeded, want a refusal: target has no inbox and --force was not given")
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
	if err := stopCmd([]string{"--force", "target"}); err != nil {
		t.Fatalf("stopCmd = %v, want success", err)
	}
	if calls := kills(); len(calls) != 1 || calls[0] != "%2" {
		t.Errorf("killPane calls = %v, want exactly one call for %%2", calls)
	}
}

// TestStopRefusesToKillASessionsOnlyWindow pins the guard killTargetPane
// shares with closeWindowCmd: here the target's pane is also the only
// pane of @1, which is $1's only window, so killing it would end the
// session and detach every client attached to it - never what stopping
// one agent asked for. --force is the strongest thing a caller can say
// and it does not buy this.
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
	if err := stopCmd([]string{"--force", "target"}); err == nil {
		t.Fatal("stopCmd succeeded, want a refusal: %2 is @1's only pane, and @1 is $1's only window")
	}
	if calls := kills(); len(calls) != 0 {
		t.Errorf("killPane calls = %v, want none", calls)
	}
}

// TestStopKillsOneOfTwoPanesInAWindow is D5's regression case: a window
// with a bystander pane beside the target. An earlier draft of stopCmd
// killed the whole window, which would have taken the bystander down
// too; only the target's own pane may go.
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
	if err := stopCmd([]string{"--force", "target"}); err != nil {
		t.Fatalf("stopCmd = %v, want success: @2 has a second pane, so it is not $1's only surviving window", err)
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

	if err := interruptCmd([]string{"peer"}); err == nil {
		t.Fatal("interruptCmd succeeded against a non-descendant, want a refusal")
	}
	if err := interruptCmd([]string{"child"}); err != nil {
		t.Fatalf("interruptCmd against an actual descendant = %v, want success", err)
	}
}

func TestStopRefusesNonDescendant(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, controlTreePanes)
	in := testutil.StartInbox(t, "ok\n")
	recordControlTree(t, in)

	if err := stopCmd([]string{"peer"}); err == nil {
		t.Fatal("stopCmd succeeded against a non-descendant, want a refusal")
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

	if err := interruptCmd([]string{"peer"}); err != nil {
		t.Fatalf("interruptCmd from an unscoped human caller = %v, want success", err)
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

	if err := interruptCmd([]string{"target"}); err != nil {
		t.Fatalf("interruptCmd = %v, want success", err)
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

// TestStopEscalatesToKillingWindow checks the escalation stopCmd's own
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

	if err := stopCmd([]string{"target"}); err != nil {
		t.Fatalf("stopCmd = %v, want success (escalated)", err)
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

	if err := stopCmd([]string{"target"}); err != nil {
		t.Fatalf("stopCmd = %v, want success", err)
	}
	if calls := kills(); len(calls) != 0 {
		t.Errorf("killPane calls = %v, want none: the target stopped in time", calls)
	}
}

// TestStopEscalatesWhenTheTargetDoesNotAgree pins the case the escalation
// exists for and an earlier draft got backwards: a wedged agent does not
// answer "ok". It holds the connection open until the deadline, or it
// answers something else, or its own scope check refuses - and in every
// one of those the request was not agreed to, which is a reason to
// escalate rather than to give up. Returning the send error here left
// kido stop failing outright, with the window intact, exactly when it was
// needed most; --force did not help, because that flag is about having no
// inbox, not about an inbox that answered badly.
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

			if err := stopCmd([]string{"target"}); err != nil {
				t.Fatalf("stopCmd = %v, want success (escalated)", err)
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
		if err := stopCmd([]string{"target"}); err == nil {
			t.Fatal("stopCmd succeeded, want a refusal: the inbox is stale and --force was not given")
		}
		if calls := kills(); len(calls) != 0 {
			t.Errorf("killPane calls = %v, want none without --force", calls)
		}
	})
	t.Run("with --force", func(t *testing.T) {
		kills := setup(t)
		if err := stopCmd([]string{"--force", "target"}); err != nil {
			t.Fatalf("stopCmd = %v, want success", err)
		}
		if calls := kills(); len(calls) != 1 || calls[0] != "%2" {
			t.Errorf("killPane calls = %v, want exactly one call for %%2", calls)
		}
	})
}

// TestControlErrorsAreNotDoublePrefixed pins that these commands leave the
// "kido <verb>: " prefix to dispatch (main.go), which adds it to every
// error it prints. Saying it here too printed "kido stop: kido stop: ..."
// at the terminal.
func TestControlErrorsAreNotDoublePrefixed(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, controlTreePanes)
	in := testutil.StartInbox(t, "ok\n")
	recordControlTree(t, in)

	for _, args := range [][]string{{"peer"}, {"caller"}} {
		for verb, run := range map[string]func([]string) error{"interrupt": interruptCmd, "stop": stopCmd} {
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
// cannot target its own pane, matching kido message's own rule.
func TestInterruptRefusesSelf(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	if err := state.Record("me", state.Session{Pane: "%1", PID: os.Getpid(), Status: state.Idle, Title: "Self"}); err != nil {
		t.Fatal(err)
	}
	if err := interruptCmd([]string{"Self"}); err == nil {
		t.Fatal("interruptCmd against self succeeded, want a refusal")
	}
}

// TestInterruptRefusedAgainstInboxlessAgent pins a behaviour that was
// already correct but untested: unlike stop, interrupt has no --force
// degrade at all (docs/subagents-plan.md's "Interrupting and stopping a
// subagent" section: "there is no destructive fallback that makes sense
// for 'redirect this, do not kill it'"), so an agent with no inbox to
// carry the request is simply refused, with nothing killed.
func TestInterruptRefusedAgainstInboxlessAgent(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	kills := withKillPane(t)

	if err := state.Record("target", state.Session{Pane: "%2", PID: os.Getpid(), Status: state.Idle}); err != nil {
		t.Fatal(err)
	}
	if err := interruptCmd([]string{"target"}); err == nil {
		t.Fatal("interruptCmd succeeded, want a refusal: target has no inbox and interrupt has no --force degrade")
	}
	if calls := kills(); len(calls) != 0 {
		t.Errorf("killPane calls = %v, want none: interrupt never kills anything", calls)
	}
}

func TestControlUsage(t *testing.T) {
	if err := interruptCmd(nil); err == nil || !strings.Contains(err.Error(), "usage") {
		t.Errorf("interruptCmd(nil) = %v, want a usage error", err)
	}
	if err := stopCmd(nil); err == nil || !strings.Contains(err.Error(), "usage") {
		t.Errorf("stopCmd(nil) = %v, want a usage error", err)
	}
}
