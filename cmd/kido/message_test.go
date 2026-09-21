package main

import (
	"errors"
	"os"
	"strings"
	"testing"

	"kido/internal/msg"
	"kido/internal/state"
	"kido/internal/testutil"
	"kido/internal/tmux"
)

// withPanes points listPanes at a fixed list for the duration of the test,
// so message never talks to a real tmux server.
func withPanes(t *testing.T, panes []tmux.Pane) {
	t.Helper()
	prev := listPanes
	listPanes = func() ([]tmux.Pane, error) { return panes, nil }
	t.Cleanup(func() { listPanes = prev })
}

// withSendPrompt replaces sendPrompt with a fake that fails with err and
// records its calls instead of talking to a real tmux server. The
// returned func reports the calls made so far.
func withSendPrompt(t *testing.T, err error) func() []string {
	t.Helper()
	prev := sendPrompt
	var calls []string
	sendPrompt = func(pane, text string) error {
		calls = append(calls, pane+": "+text)
		return err
	}
	t.Cleanup(func() { sendPrompt = prev })
	return func() []string { return calls }
}

// samePane is the one-session pane fixture most of these tests use: the
// caller at %1 and every target somewhere in the same session, "$1".
var samePane = []tmux.Pane{
	{PaneID: "%1", SessionID: "$1"},
	{PaneID: "%2", SessionID: "$1"},
	{PaneID: "%3", SessionID: "$1"},
}

// TestMessageV0RawText checks that a target with no advertised protocol
// (state.Session.Protocol zero) gets plain v0 text, byte for byte - the
// same contract kido prompt relies on, so an unupgraded receiver still
// sees exactly its prompt and not a JSON envelope.
func TestMessageV0RawText(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)

	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path,
	}); err != nil {
		t.Fatal(err)
	}

	if code := message([]string{"target"}, strings.NewReader("hello there")); code != 0 {
		t.Fatalf("message = %d, want 0", code)
	}
	msgs := in.Received()
	if len(msgs) != 1 || msgs[0] != "hello there" {
		t.Fatalf("server got %q, want v0 raw text [%q]", msgs, "hello there")
	}
}

// TestMessageV1Envelope checks that a target advertising protocol 1 gets a
// v1 JSON envelope with kind "message" and the text intact, and that
// --reply-to lands in the envelope's ReplyTo.
func TestMessageV1Envelope(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)

	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path, Protocol: msg.V1,
	}); err != nil {
		t.Fatal(err)
	}

	if code := message([]string{"--reply-to", "ask-1", "target"}, strings.NewReader("hi there")); code != 0 {
		t.Fatalf("message = %d, want 0", code)
	}
	msgs := in.Received()
	if len(msgs) != 1 {
		t.Fatalf("server got %d messages, want 1: %q", len(msgs), msgs)
	}
	env, ok := msg.Parse([]byte(msgs[0]))
	if !ok {
		t.Fatalf("payload %q did not parse as a v1 envelope", msgs[0])
	}
	if env.Kind != msg.KindMessage || env.Text != "hi there" || env.ID == "" {
		t.Errorf("envelope = %+v, want kind message, text %q, a non-empty id", env, "hi there")
	}
	if env.ReplyTo != "ask-1" {
		t.Errorf("envelope.ReplyTo = %q, want %q", env.ReplyTo, "ask-1")
	}
}

// TestMessageResolveByName checks that an exact, case-insensitive title
// match wins outright, even when it would also be a valid id prefix of
// something else.
func TestMessageResolveByName(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)

	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("abc123", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path, Title: "Worker-2",
	}); err != nil {
		t.Fatal(err)
	}

	if code := message([]string{"worker-2"}, strings.NewReader("x")); code != 0 {
		t.Errorf("code = %d, want 0", code)
	}
	if msgs := in.Received(); len(msgs) != 1 {
		t.Fatalf("server got %q, want one message", msgs)
	}
}

// TestMessageResolveAmbiguity checks the three addressing rules and their
// ambiguity errors: two sessions with the same title, an id prefix that
// matches two ids, and a target found nowhere at all.
func TestMessageResolveAmbiguity(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, []tmux.Pane{
		{PaneID: "%1", SessionID: "$1"},
		{PaneID: "%2", SessionID: "$1"},
		{PaneID: "%3", SessionID: "$1"},
		{PaneID: "%4", SessionID: "$1"},
		{PaneID: "%5", SessionID: "$1"},
	})

	inA := testutil.StartInbox(t, "ok\n")
	inB := testutil.StartInbox(t, "ok\n")
	if err := state.Record("abc123", state.Session{Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: inA.Path}); err != nil {
		t.Fatal(err)
	}
	if err := state.Record("abd456", state.Session{Pane: "%3", PID: os.Getpid(), Status: state.Idle, Inbox: inB.Path}); err != nil {
		t.Fatal(err)
	}
	if err := state.Record("worker-x", state.Session{Pane: "%4", PID: os.Getpid(), Status: state.Idle, Title: "scout"}); err != nil {
		t.Fatal(err)
	}
	if err := state.Record("worker-y", state.Session{Pane: "%5", PID: os.Getpid(), Status: state.Idle, Title: "scout"}); err != nil {
		t.Fatal(err)
	}

	if code := message([]string{"abc123"}, strings.NewReader("x")); code != 0 {
		t.Errorf("exact id: code = %d, want 0", code)
	}
	if code := message([]string{"abc"}, strings.NewReader("x")); code != 0 {
		t.Errorf("unique prefix: code = %d, want 0", code)
	}
	if code := message([]string{"ab"}, strings.NewReader("x")); code == 0 {
		t.Error("ambiguous id prefix: code = 0, want an error")
	}
	if code := message([]string{"nope"}, strings.NewReader("x")); code == 0 {
		t.Error("no match: code = 0, want an error")
	}
	if code := message([]string{"scout"}, strings.NewReader("x")); code == 0 {
		t.Error("ambiguous name: code = 0, want an error")
	}
}

// TestMessageOutOfSession checks that an agent that exists but lives in a
// different tmux session is reported as unaddressable, not "not found" -
// resolveTarget must name the reason rather than pretend it saw nothing.
func TestMessageOutOfSession(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, []tmux.Pane{
		{PaneID: "%1", SessionID: "$1"},
		{PaneID: "%9", SessionID: "$2"},
	})

	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("elsewhere", state.Session{
		Pane: "%9", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path, Title: "far-away",
	}); err != nil {
		t.Fatal(err)
	}

	code := message([]string{"elsewhere"}, strings.NewReader("x"))
	if code == 0 {
		t.Fatal("code = 0, want an error: elsewhere is in another session")
	}
	if in.Received() != nil {
		t.Error("message reached the far-session inbox; it must not be addressable")
	}
}

// TestMessageNoInboxPastes checks the Claude-pane fallback: a live agent
// in scope that has reported no inbox at all still gets the message,
// pasted into its pane exactly as kido prompt would.
func TestMessageNoInboxPastes(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	pastes := withSendPrompt(t, nil)

	if err := state.Record("target", state.Session{Pane: "%2", PID: os.Getpid(), Status: state.Idle}); err != nil {
		t.Fatal(err)
	}
	if code := message([]string{"target"}, strings.NewReader("hi claude")); code != 0 {
		t.Fatalf("code = %d, want 0", code)
	}
	calls := pastes()
	if len(calls) != 1 || calls[0] != "%2: hi claude" {
		t.Fatalf("sendPrompt calls = %v, want one paste of the raw text into %%2", calls)
	}
}

// TestMessageInboxHardErrorNoFallback checks the AGENTS.md rule that a
// non-errInboxUnavailable failure must never fall back to a paste: the
// message may already have reached the agent, and pasting it again would
// double-send.
func TestMessageInboxHardErrorNoFallback(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	pastes := withSendPrompt(t, errors.New("sendPrompt must not be called"))

	// A reply other than "ok" is a hard error from deliverInbox, not
	// errInboxUnavailable (see TestDeliverInboxBadReply).
	in := testutil.StartInbox(t, "nope\n")
	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path,
	}); err != nil {
		t.Fatal(err)
	}

	if code := message([]string{"target"}, strings.NewReader("x")); code == 0 {
		t.Fatal("code = 0, want an error: the inbox failure must not be swallowed")
	}
	if calls := pastes(); len(calls) != 0 {
		t.Errorf("sendPrompt was called %v, want no fallback on a hard inbox error", calls)
	}
}

// TestMessageEmptyStdin checks that empty input is rejected before kido
// resolves a target at all.
func TestMessageEmptyStdin(t *testing.T) {
	if code := message([]string{"whoever"}, strings.NewReader("")); code != 1 {
		t.Errorf("code = %d, want 1", code)
	}
}

// TestMessageUsage checks argument-count errors: no target and more than
// one positional argument are both rejected.
func TestMessageUsage(t *testing.T) {
	if code := message(nil, strings.NewReader("x")); code != 1 {
		t.Errorf("no target: code = %d, want 1", code)
	}
	if code := message([]string{"a", "b"}, strings.NewReader("x")); code != 1 {
		t.Errorf("two targets: code = %d, want 1", code)
	}
}

// TestResolveTargetAmbiguousElsewhere checks the error for a name that
// matches nothing in scope and several agents outside it. matchTarget
// reports an ambiguity with a zero state.Session, so the out-of-session
// branch must not name its id: it would print an empty one and claim a
// single match where there were several.
func TestResolveTargetAmbiguousElsewhere(t *testing.T) {
	panes := []tmux.Pane{
		{PaneID: "%1", SessionID: "$1"},
		{PaneID: "%8", SessionID: "$2"},
		{PaneID: "%9", SessionID: "$2"},
	}
	states := map[string]state.Session{
		"twin-a": {ID: "twin-a", Pane: "%8", Title: "Twin"},
		"twin-b": {ID: "twin-b", Pane: "%9", Title: "Twin"},
	}

	_, err := resolveTarget(states, panes, "%1", "Twin")
	if err == nil {
		t.Fatal("resolveTarget succeeded, want an ambiguity error")
	}
	got := err.Error()
	for _, want := range []string{"twin-a", "twin-b", "several", "tmux session"} {
		if !strings.Contains(got, want) {
			t.Errorf("error %q does not mention %q", got, want)
		}
	}
	if strings.Contains(got, "()") {
		t.Errorf("error %q names an empty session id", got)
	}
}

// TestMessageRefusesSelf checks that an agent cannot address its own
// pane. list_agents reports the caller alongside its peers, so a model
// picking a name off that list can pick its own, and delivering would
// hand it its own message back as a fresh user turn.
func TestMessageRefusesSelf(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	pastes := withSendPrompt(t, errors.New("sendPrompt must not be called"))

	if err := state.Record("me", state.Session{
		Pane: "%1", PID: os.Getpid(), Status: state.Idle, Title: "Self",
	}); err != nil {
		t.Fatal(err)
	}
	if code := message([]string{"Self"}, strings.NewReader("talking to myself")); code != 1 {
		t.Fatalf("code = %d, want 1", code)
	}
	if calls := pastes(); len(calls) != 0 {
		t.Fatalf("sendPrompt calls = %v, want none", calls)
	}
}

// TestMessageRefusesInvalidUTF8 pins that a message is refused rather
// than delivered differently by each path: the inbox marshals it into
// JSON, which substitutes U+FFFD for an invalid byte, while a paste
// writes the byte through untouched.
func TestMessageRefusesInvalidUTF8(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, samePane)
	pastes := withSendPrompt(t, errors.New("sendPrompt must not be called"))

	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Title: "Alpha",
	}); err != nil {
		t.Fatal(err)
	}
	if code := message([]string{"Alpha"}, strings.NewReader("bad:\xff\xfe:end")); code != 1 {
		t.Fatalf("code = %d, want 1", code)
	}
	if calls := pastes(); len(calls) != 0 {
		t.Fatalf("sendPrompt calls = %v, want none", calls)
	}
}
