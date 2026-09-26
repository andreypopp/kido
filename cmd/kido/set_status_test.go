package main

import (
	"os"
	"strings"
	"testing"
	"time"

	"kido/internal/state"
)

// TestSetStatusSetsOnlyTheActivity pins the whole of `kido set_status`:
// it finds the caller's own session by pane, writes the activity, and
// leaves every other field of the record exactly as the agent last
// reported it. The record here is deliberately full of things a rebuilt
// record would lose - the status, the inbox and protocol, the parent
// edge, the background flag, the turn's end time, and TS, which
// state.Stalled reads - because the tempting implementation (hand the
// fields to `kido agent-status` and let it write a fresh record) drops
// whichever of them has no flag.
func TestSetStatusSetsOnlyTheActivity(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%7")

	before := state.Session{
		Agent: state.AgentPi, Pane: "%7", PID: os.Getpid(), Status: state.Running, Title: "worker",
		Inbox: "/tmp/nope.sock", Protocol: 1, Background: true,
		Ended: time.Date(2024, 3, 1, 12, 0, 0, 0, time.UTC), TS: time.Date(2024, 3, 1, 12, 5, 0, 0, time.UTC),
		Activity: "the old one", ParentSession: "parent-sess",
		ParentPID: 4242, Depth: 1, Model: "claude-sonnet-5",
	}
	if err := state.Record("worker-session", before); err != nil {
		t.Fatal(err)
	}

	if err := setStatusCmd([]string{"--", "refactoring internal/ui"}); err != nil {
		t.Fatalf("set_status: %v", err)
	}

	after, ok, err := state.Get("worker-session")
	if err != nil || !ok {
		t.Fatalf("state.Get: %v, ok = %v", err, ok)
	}
	if after.Activity != "refactoring internal/ui" {
		t.Errorf("activity = %q, want the one just set", after.Activity)
	}
	want := before
	want.ID, want.Activity = after.ID, after.Activity
	if after != want {
		t.Errorf("record = %+v, want %+v: only the activity may change", after, want)
	}
}

// TestSetStatusOneLineAndClear covers the two arguments a model can give
// that are not plain text: control characters, which the sidebar budgets
// one terminal line per row and does not defend itself against, and the
// empty string, which clears rather than being refused as missing.
func TestSetStatusOneLineAndClear(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%7")
	if err := state.Record("s", state.Session{Pane: "%7", PID: os.Getpid(), Status: state.Idle}); err != nil {
		t.Fatal(err)
	}

	if err := setStatusCmd([]string{"--", "two\nlines\tand more"}); err != nil {
		t.Fatalf("set_status: %v", err)
	}
	got, _, _ := state.Get("s")
	if strings.ContainsAny(got.Activity, "\n\t") {
		t.Errorf("activity = %q, want control characters flattened", got.Activity)
	}

	if err := setStatusCmd([]string{"--", ""}); err != nil {
		t.Fatalf("set_status with an empty activity: %v", err)
	}
	if got, _, _ := state.Get("s"); got.Activity != "" {
		t.Errorf("activity = %q, want an empty argument to clear it", got.Activity)
	}
}

// TestSetStatusUsage: no agent record for this pane is an error, since
// there is no session whose activity this would be, and so are no
// argument and more than one.
func TestSetStatusUsage(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%7")

	if err := setStatusCmd([]string{"--", "busy"}); err == nil {
		t.Error("set_status from a pane with no agent record succeeded, want an error")
	}
	if err := setStatusCmd(nil); err == nil {
		t.Error("set_status with no activity succeeded, want a usage error")
	}
	if err := setStatusCmd([]string{"one", "two"}); err == nil {
		t.Error("set_status with two arguments succeeded, want a usage error")
	}
}
