package main

import (
	"os"
	"strings"
	"testing"
	"time"

	"kido/internal/state"
	"kido/internal/testutil"
	"kido/internal/tmux"
)

// TestAgentAliveSurvivesAPaneCollisionOnTheParent: a second live agent
// claiming the parent's own pane wins that pane in state.Load's
// per-pane view, and the parent's record is then not in that answer at
// all - but agent-alive must still say true. The lossy view is
// exercised as a negative control below. Same shape as internal/reap's
// TestSweepSurvivesAPaneCollisionOnTheParent.
func TestAgentAliveSurvivesAPaneCollisionOnTheParent(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	t.Setenv("TMUX_PANE", "%1")
	withPanes(t, []tmux.Pane{
		{PaneID: "%p", SessionID: "$1", WindowID: "@p"},
		{PaneID: "%1", SessionID: "$1", WindowID: "@1"},
	})
	live := time.Now()
	for _, s := range []state.Session{
		{ID: "parent", Pane: "%p", PID: os.Getpid(), Agent: state.AgentPi,
			Status: state.Idle, TS: live},
		{ID: "child", Pane: "%1", PID: os.Getpid(), Agent: state.AgentPi,
			Status: state.Idle, Parent: state.NewParent("parent", 0), TS: live},
		{ID: "intruder", Pane: "%p", PID: os.Getpid(), Agent: state.AgentPi,
			Status: state.Idle, TS: live.Add(time.Second)},
	} {
		if err := state.Record(s.ID, s); err != nil {
			t.Fatal(err)
		}
	}

	var err error
	out := capture(t, &os.Stdout, func() { err = agentAliveCmd([]string{"parent"}) })
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(out) != "true" {
		t.Errorf("agent-alive parent = %q, want %q: the parent is plainly running, collision or not", strings.TrimSpace(out), "true")
	}

	byPane, lerr := state.Load()
	if lerr != nil {
		t.Fatal(lerr)
	}
	if byPane["%p"].ID != "intruder" {
		t.Fatalf("state.Load has %+v on the parent's pane, want the intruder to have won it", byPane["%p"])
	}
	panes, perr := listPanes()
	if perr != nil {
		t.Fatal(perr)
	}
	for _, a := range buildAgents(byPane, panes, "$1", "%1") {
		if a.ID == "child" && a.Parent != "" {
			t.Fatalf("kido list_agents resolved the child's parent as %q; the control no longer reproduces the loss", a.Parent)
		}
	}
}

// TestAgentAliveGoneAndUnknown: a session nobody holds is "false",
// not an error - a definite answer the caller acts on - and so is one
// whose process has died, which LoadLive drops. The child's poll tells
// that apart from kido being unreachable by the exit code, so "false"
// must never come with one.
func TestAgentAliveGoneAndUnknown(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := state.Record("dead-sess", state.Session{Pane: "%9", PID: testutil.DeadPID(t),
		Agent: state.AgentPi, Status: state.Idle, TS: time.Now()}); err != nil {
		t.Fatal(err)
	}
	for _, session := range []string{"dead-sess", "never-existed"} {
		var err error
		out := capture(t, &os.Stdout, func() { err = agentAliveCmd([]string{session}) })
		if err != nil {
			t.Fatalf("agent-alive %s: %v", session, err)
		}
		if strings.TrimSpace(out) != "false" {
			t.Errorf("agent-alive %s = %q, want %q", session, strings.TrimSpace(out), "false")
		}
	}
}

// TestAgentAliveUsage: a missing or empty session is a usage error
// rather than a silent "false", which a caller would read as a dead
// parent and act on.
func TestAgentAliveUsage(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	for _, args := range [][]string{{}, {""}, {"a", "b"}} {
		if err := agentAliveCmd(args); err == nil {
			t.Errorf("agent-alive %q: want a usage error", args)
		}
	}
}

// TestAgentAliveFollowsARestartedSession: a parent that was quit and
// resumed (`pi --resume`) keeps its session id and gets a new process,
// so the liveness poll must be answered about the session. A child that
// polled for the old process would shut itself down minutes after every
// restart.
func TestAgentAliveFollowsARestartedSession(t *testing.T) {
	t.Setenv("KIDO_STATE_DIR", t.TempDir())
	if err := state.Record("parent-sess", state.Session{Pane: "%p", PID: os.Getpid(),
		Agent: state.AgentPi, Status: state.Idle, TS: time.Now()}); err != nil {
		t.Fatal(err)
	}
	var err error
	out := capture(t, &os.Stdout, func() { err = agentAliveCmd([]string{"parent-sess"}) })
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(out) != "true" {
		t.Errorf("agent-alive parent-sess = %q, want %q", strings.TrimSpace(out), "true")
	}
}
