package main

import (
	"os"
	"strings"
	"testing"

	"kido/internal/msg"
	"kido/internal/state"
	"kido/internal/testutil"
)

// TestMessageV0RawText checks that a target with no advertised protocol
// (state.Session.Protocol zero) gets plain v0 text, byte for byte - the
// same contract kido prompt relies on, so an unupgraded receiver still
// sees exactly its prompt and not a JSON envelope.
func TestMessageV0RawText(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")

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
// v1 JSON envelope with kind "message" and the text intact.
func TestMessageV1Envelope(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")

	in := testutil.StartInbox(t, "ok\n")
	if err := state.Record("target", state.Session{
		Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: in.Path, Protocol: msg.V1,
	}); err != nil {
		t.Fatal(err)
	}

	if code := message([]string{"target"}, strings.NewReader("hi there")); code != 0 {
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
}

// TestMessagePrefixResolution checks the three addressing outcomes: an
// exact id, a unique prefix, and an ambiguous prefix.
func TestMessagePrefixResolution(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")

	inA := testutil.StartInbox(t, "ok\n")
	inB := testutil.StartInbox(t, "ok\n")
	if err := state.Record("abc123", state.Session{Pane: "%2", PID: os.Getpid(), Status: state.Idle, Inbox: inA.Path}); err != nil {
		t.Fatal(err)
	}
	if err := state.Record("abd456", state.Session{Pane: "%3", PID: os.Getpid(), Status: state.Idle, Inbox: inB.Path}); err != nil {
		t.Fatal(err)
	}

	if code := message([]string{"abc123"}, strings.NewReader("x")); code != 0 {
		t.Errorf("exact id: code = %d, want 0", code)
	}
	if code := message([]string{"abc"}, strings.NewReader("x")); code != 0 {
		t.Errorf("unique prefix: code = %d, want 0", code)
	}
	if code := message([]string{"ab"}, strings.NewReader("x")); code == 0 {
		t.Error("ambiguous prefix: code = 0, want an error")
	}
	if code := message([]string{"nope"}, strings.NewReader("x")); code == 0 {
		t.Error("no match: code = 0, want an error")
	}
}

// TestMessageNoInbox checks that a live agent with no reported inbox is an
// error, not a send-keys fallback: message only ever targets an inbox.
func TestMessageNoInbox(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")

	if err := state.Record("target", state.Session{Pane: "%2", PID: os.Getpid(), Status: state.Idle}); err != nil {
		t.Fatal(err)
	}
	if code := message([]string{"target"}, strings.NewReader("x")); code == 0 {
		t.Error("code = 0, want an error for a target with no inbox")
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

